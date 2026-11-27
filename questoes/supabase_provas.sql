-- =====================================================================
--  PROVAS · Sala de Questões  (rode DEPOIS do supabase.sql; pode repetir)
--  Cole tudo no SQL Editor do Supabase e clique em RUN.
-- =====================================================================
create table if not exists public.exams(
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 120),
  class text,                                   -- null = todas as turmas
  minutes int check (minutes is null or minutes between 1 and 600),
  show_score boolean not null default true,
  is_open boolean not null default false,
  questions jsonb not null default '[]'::jsonb, -- com gabarito: só o professor lê
  created_at timestamptz not null default now()
);
create table if not exists public.exam_attempts(
  exam_id uuid not null references public.exams(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  idx int not null default 0,
  answers jsonb not null default '[]'::jsonb,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  points numeric,
  pct int,
  primary key (exam_id, student_id)
);
alter table public.exams enable row level security;
alter table public.exam_attempts enable row level security;
revoke all on public.exams, public.exam_attempts from anon, authenticated;

-- ---------- correção (servidor) ----------
create or replace function public._exam_grade(q jsonb, a jsonb)
returns numeric language plpgsql immutable as $$
declare n int; ok int := 0; i int; f jsonb; v jsonb;
begin
  if a is null or a = 'null'::jsonb then return 0; end if;
  if q->>'t' = 'mc' then
    return case when jsonb_typeof(a) = 'number' and (a#>>'{}')::numeric = (q->>'a')::numeric then 1 else 0 end;
  elsif q->>'t' = 'vf' then
    if jsonb_typeof(a) <> 'array' then return 0; end if;
    n := jsonb_array_length(q->'items'); if n = 0 then return 0; end if;
    for i in 0..n-1 loop
      if (a->i) = (q->'items'->i->1) then ok := ok + 1; end if;
    end loop;
    return ok::numeric / n;
  elsif q->>'t' = 'fields' then
    if jsonb_typeof(a) <> 'array' then return 0; end if;
    n := jsonb_array_length(q->'f'); if n = 0 then return 0; end if;
    for i in 0..n-1 loop
      f := q->'f'->i; v := a->i;
      if jsonb_typeof(v) = 'number' then
        if f->>'t' = 'sel' then
          if (v#>>'{}')::numeric = (f->>'a')::numeric then ok := ok + 1; end if;
        elsif abs((v#>>'{}')::numeric - (f->>'a')::numeric) <= greatest(coalesce((f->>'tol')::numeric,0), 0.000000001) then ok := ok + 1; end if;
      end if;
    end loop;
    return ok::numeric / n;
  end if;
  return 0;
end $$;

-- pergunta sem gabarito, para o aluno
create or replace function public._exam_strip(q jsonb)
returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    't', q->>'t', 'q', q->>'q', 'fig', q->>'fig',
    'o', q->'o',
    'items', case when q->>'t'='vf' then (select jsonb_agg(e->0) from jsonb_array_elements(q->'items') e) end,
    'f', case when q->>'t'='fields' then (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('t',e->>'t','l',e->>'l','o',e->'o','u',e->>'u'))) from jsonb_array_elements(q->'f') e) end))
$$;

create or replace function public._exam_finish(p_exam uuid, p_student uuid)
returns void language plpgsql security definer set search_path = public as $$
declare ex public.exams%rowtype; at public.exam_attempts%rowtype; i int; n int; tot numeric := 0; got numeric := 0; w numeric;
begin
  select * into ex from public.exams where id = p_exam;
  select * into at from public.exam_attempts where exam_id = p_exam and student_id = p_student;
  n := jsonb_array_length(ex.questions);
  for i in 0..n-1 loop
    w := coalesce((ex.questions->i->>'w')::numeric, 1); tot := tot + w;
    got := got + w * public._exam_grade(ex.questions->i, at.answers->i);
  end loop;
  update public.exam_attempts set finished_at = now(), points = round(got,2),
         pct = case when tot > 0 then round(got / tot * 100) else 0 end
   where exam_id = p_exam and student_id = p_student;
end $$;

-- ---------- ALUNO ----------
create or replace function public.student_exams(p_name text, p_class text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb; sid uuid; cls text;
begin
  a := public._auth_student(p_name, p_class, p_pin);
  if a ? 'error' then return a; end if;
  sid := (a->>'id')::uuid; cls := a->>'class';
  return jsonb_build_object('exams', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'title', e.title, 'minutes', e.minutes, 'total', jsonb_array_length(e.questions),
      'state', case when t.finished_at is not null then 'done' when t.exam_id is not null then 'going' else 'new' end,
      'pct', case when t.finished_at is not null and e.show_score then t.pct end,
      'points', case when t.finished_at is not null and e.show_score then t.points end
    ) order by e.created_at desc), '[]'::jsonb)
    from public.exams e left join public.exam_attempts t on t.exam_id = e.id and t.student_id = sid
    where (e.is_open or t.finished_at is not null) and (e.class is null or lower(e.class) = lower(cls))));
end $$;

-- p_answer null = começar/retomar; senão grava a resposta da questão atual e avança
create or replace function public.student_exam_step(p_name text, p_class text, p_pin text, p_exam uuid, p_answer jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb; sid uuid; ex public.exams%rowtype; t public.exam_attempts%rowtype; n int; late boolean;
begin
  a := public._auth_student(p_name, p_class, p_pin);
  if a ? 'error' then return a; end if;
  sid := (a->>'id')::uuid;
  select * into ex from public.exams where id = p_exam;
  if not found or (ex.class is not null and lower(ex.class) <> lower(a->>'class')) then
    return jsonb_build_object('error','Prova não encontrada.'); end if;
  select * into t from public.exam_attempts where exam_id = p_exam and student_id = sid;
  if not found then
    if not ex.is_open then return jsonb_build_object('error','Esta prova não está aberta.'); end if;
    insert into public.exam_attempts(exam_id, student_id) values (p_exam, sid)
      on conflict do nothing;
    select * into t from public.exam_attempts where exam_id = p_exam and student_id = sid;
  end if;
  n := jsonb_array_length(ex.questions);
  if t.finished_at is null then
    late := ex.minutes is not null and now() > t.started_at + (ex.minutes || ' minutes')::interval + interval '10 seconds';
    if not ex.is_open or late then
      perform public._exam_finish(p_exam, sid);
    elsif p_answer is not null and 'null'::jsonb <> p_answer then
      update public.exam_attempts set answers = answers || jsonb_build_array(p_answer), idx = idx + 1
       where exam_id = p_exam and student_id = sid and idx = t.idx;
      if t.idx + 1 >= n or (ex.minutes is not null and now() > t.started_at + (ex.minutes || ' minutes')::interval) then
        perform public._exam_finish(p_exam, sid); end if;
    end if;
    select * into t from public.exam_attempts where exam_id = p_exam and student_id = sid;
  end if;
  if t.finished_at is not null or t.idx >= n then
    if t.finished_at is null then perform public._exam_finish(p_exam, sid);
      select * into t from public.exam_attempts where exam_id = p_exam and student_id = sid; end if;
    return jsonb_build_object('state','done','title',ex.title,
      'pct', case when ex.show_score then t.pct end, 'points', case when ex.show_score then t.points end,
      'shown', ex.show_score);
  end if;
  return jsonb_build_object('state','q','title',ex.title,'idx',t.idx,'total',n,
    'q', public._exam_strip(ex.questions->t.idx),
    'left', case when ex.minutes is null then null else greatest(0, extract(epoch from (t.started_at + (ex.minutes || ' minutes')::interval - now()))::int) end);
end $$;

-- ---------- PROFESSOR ----------
create or replace function public.teacher_exam_save(p_id uuid, p_title text, p_class text, p_minutes int, p_show boolean, p_questions jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  if jsonb_typeof(p_questions) <> 'array' or jsonb_array_length(p_questions) = 0 then raise exception 'Escolha pelo menos uma questão'; end if;
  if p_id is not null and exists (select 1 from public.exam_attempts where exam_id = p_id) then
    update public.exams set title = p_title, class = nullif(btrim(p_class),''), minutes = p_minutes, show_score = p_show where id = p_id;
    return p_id;  -- com alunos já respondendo, as questões não mudam
  end if;
  if p_id is not null then
    update public.exams set title = p_title, class = nullif(btrim(p_class),''), minutes = p_minutes, show_score = p_show, questions = p_questions where id = p_id returning id into v;
    if v is not null then return v; end if;
  end if;
  insert into public.exams(title, class, minutes, show_score, questions)
  values (p_title, nullif(btrim(p_class),''), p_minutes, p_show, p_questions) returning id into v;
  return v;
end $$;

create or replace function public.teacher_exam_list()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'class',e.class,'minutes',e.minutes,'show_score',e.show_score,
     'is_open',e.is_open,'total',jsonb_array_length(e.questions),'created_at',e.created_at,
     'started',(select count(*) from public.exam_attempts t where t.exam_id=e.id),
     'finished',(select count(*) from public.exam_attempts t where t.exam_id=e.id and t.finished_at is not null)) order by e.created_at desc),'[]'::jsonb) from public.exams e);
end $$;

create or replace function public.teacher_exam_get(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  return (select to_jsonb(e) from public.exams e where e.id = p_id);
end $$;

create or replace function public.teacher_exam_set_open(p_id uuid, p_open boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  update public.exams set is_open = p_open where id = p_id;
end $$;

create or replace function public.teacher_exam_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  delete from public.exams where id = p_id;
end $$;

create or replace function public.teacher_exam_results(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ex public.exams%rowtype; i int;
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  select * into ex from public.exams where id = p_id;
  if not found then raise exception 'Prova não encontrada'; end if;
  return jsonb_build_object('title', ex.title, 'total', jsonb_array_length(ex.questions),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('student_id',s.id,'name',s.name,'class',s.class,'idx',t.idx,
        'started_at',t.started_at,'finished_at',t.finished_at,'points',t.points,'pct',t.pct,
        'scores', (select coalesce(jsonb_agg(round(public._exam_grade(ex.questions->g, t.answers->g),3) order by g),'[]'::jsonb)
                     from generate_series(0, least(t.idx, jsonb_array_length(ex.questions)) - 1) g)
      ) order by s.class, s.name),'[]'::jsonb)
      from public.exam_attempts t join public.students s on s.id = t.student_id where t.exam_id = p_id));
end $$;

create or replace function public.teacher_exam_reset(p_id uuid, p_student uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  delete from public.exam_attempts where exam_id = p_id and student_id = p_student;
end $$;

-- ---------- permissões ----------
revoke all on function public._exam_grade(jsonb,jsonb), public._exam_strip(jsonb), public._exam_finish(uuid,uuid) from public, anon, authenticated;
revoke all on function public.student_exams(text,text,text), public.student_exam_step(text,text,text,uuid,jsonb),
  public.teacher_exam_save(uuid,text,text,int,boolean,jsonb), public.teacher_exam_list(), public.teacher_exam_get(uuid),
  public.teacher_exam_set_open(uuid,boolean), public.teacher_exam_delete(uuid), public.teacher_exam_results(uuid),
  public.teacher_exam_reset(uuid,uuid) from public;
grant execute on function public.student_exams(text,text,text), public.student_exam_step(text,text,text,uuid,jsonb) to anon, authenticated;
grant execute on function public.teacher_exam_save(uuid,text,text,int,boolean,jsonb), public.teacher_exam_list(), public.teacher_exam_get(uuid),
  public.teacher_exam_set_open(uuid,boolean), public.teacher_exam_delete(uuid), public.teacher_exam_results(uuid),
  public.teacher_exam_reset(uuid,uuid) to authenticated;
