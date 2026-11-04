-- =====================================================================
--  Sala de Questões · Fábrica Maluca do Relê  ·  banco de dados Supabase
--  Cole TUDO no "SQL Editor" do Supabase e clique em RUN (pode repetir).
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

-- ---------- tabelas ----------
create table if not exists public.students(
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 60),
  class text not null check (char_length(class) between 1 and 30),
  pin_hash text not null,
  fails int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists students_uq on public.students (lower(name), lower(class));

create table if not exists public.results(
  student_id uuid not null references public.students(id) on delete cascade,
  phase int not null,
  pct int not null,
  stars int not null,
  tries int not null default 1,
  updated_at timestamptz not null default now(),
  primary key (student_id, phase)
);
create table if not exists public.answers(
  student_id uuid not null references public.students(id) on delete cascade,
  qid text not null,
  score numeric not null,
  tries int not null default 1,
  updated_at timestamptz not null default now(),
  primary key (student_id, qid)
);
create table if not exists public.closed_phases(phase int primary key);
create table if not exists public.teachers(user_id uuid primary key references auth.users(id) on delete cascade);

-- ninguém lê as tabelas direto: só pelas funções abaixo
alter table public.students enable row level security;
alter table public.results enable row level security;
alter table public.answers enable row level security;
alter table public.closed_phases enable row level security;
alter table public.teachers enable row level security;
revoke all on public.students, public.results, public.answers, public.closed_phases, public.teachers from anon, authenticated;

-- ---------- funções internas ----------
create or replace function public._auth_student(p_name text, p_class text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.students%rowtype;
begin
  select * into s from public.students
   where lower(name) = lower(regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g'))
     and lower(class) = lower(btrim(coalesce(p_class,'')));
  if not found then
    return jsonb_build_object('error','Usuário não encontrado. Confira nome e turma, ou crie um usuário.');
  end if;
  if s.locked_until is not null and s.locked_until > now() then
    return jsonb_build_object('error','Muitas tentativas erradas. Aguarde 5 minutos e tente de novo.');
  end if;
  if s.pin_hash <> crypt(coalesce(p_pin,''), s.pin_hash) then
    update public.students
       set fails = case when fails + 1 >= 5 then 0 else fails + 1 end,
           locked_until = case when fails + 1 >= 5 then now() + interval '5 minutes' else locked_until end
     where id = s.id;
    return jsonb_build_object('error','PIN incorreto.');
  end if;
  if s.fails > 0 or s.locked_until is not null then
    update public.students set fails = 0, locked_until = null where id = s.id;
  end if;
  return jsonb_build_object('id', s.id, 'name', s.name, 'class', s.class);
end $$;

create or replace function public._payload(p_id uuid)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'id', s.id, 'name', s.name, 'class', s.class,
    'results', (select coalesce(jsonb_agg(jsonb_build_object('phase',r.phase,'pct',r.pct,'stars',r.stars,'tries',r.tries)), '[]'::jsonb)
                  from public.results r where r.student_id = s.id),
    'closed', (select coalesce(jsonb_agg(phase), '[]'::jsonb) from public.closed_phases))
  from public.students s where s.id = p_id
$$;

create or replace function public._is_teacher()
returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from public.teachers where user_id = auth.uid())
$$;

-- ---------- funções do ALUNO ----------
create or replace function public.student_signup(p_name text, p_class text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare n text; c text; v uuid;
begin
  n := regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g');
  c := btrim(coalesce(p_class,''));
  if char_length(n) < 2 or char_length(n) > 60 then return jsonb_build_object('error','Digite seu nome (2 a 60 letras).'); end if;
  if char_length(c) < 1 or char_length(c) > 30 then return jsonb_build_object('error','Digite sua turma.'); end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then return jsonb_build_object('error','O PIN deve ter exatamente 4 números.'); end if;
  if exists (select 1 from public.students where lower(name) = lower(n) and lower(class) = lower(c)) then
    return jsonb_build_object('error','Esse nome já existe nessa turma. Se é você, use "Entrar". Se é outra pessoa, acrescente o sobrenome.');
  end if;
  insert into public.students(name, class, pin_hash) values (n, c, crypt(p_pin, gen_salt('bf'))) returning id into v;
  return public._payload(v);
exception when unique_violation then
  return jsonb_build_object('error','Esse nome já existe nessa turma.');
end $$;

create or replace function public.student_login(p_name text, p_class text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb;
begin
  a := public._auth_student(p_name, p_class, p_pin);
  if a ? 'error' then return a; end if;
  return public._payload((a->>'id')::uuid);
end $$;

create or replace function public.student_save(p_name text, p_class text, p_pin text, p_phase int, p_pct int, p_scores jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb; sid uuid; st int; pc int; k text; v text;
begin
  a := public._auth_student(p_name, p_class, p_pin);
  if a ? 'error' then return a; end if;
  sid := (a->>'id')::uuid;
  if p_phase is null or p_phase < 1 or p_phase > 999 then return jsonb_build_object('error','Fase inválida.'); end if;
  if exists (select 1 from public.closed_phases where phase = p_phase) then
    return jsonb_build_object('error','Esta fase está bloqueada pelo professor.');
  end if;
  pc := greatest(0, least(100, coalesce(p_pct, 0)));
  st := case when pc >= 85 then 3 when pc >= 65 then 2 when pc >= 40 then 1 else 0 end;
  insert into public.results(student_id, phase, pct, stars, tries)
       values (sid, p_phase, pc, st, 1)
  on conflict (student_id, phase) do update
     set pct = greatest(public.results.pct, excluded.pct),
         stars = greatest(public.results.stars, excluded.stars),
         tries = public.results.tries + 1,
         updated_at = now();
  if p_scores is not null and jsonb_typeof(p_scores) = 'object' then
    for k, v in select key, value from jsonb_each_text(p_scores) loop
      if k ~ '^[LC][0-9]{1,3}\.[0-9]{1,2}$' and v ~ '^[0-9]*\.?[0-9]+$' then
        insert into public.answers(student_id, qid, score) values (sid, k, least(1, v::numeric))
        on conflict (student_id, qid) do update
           set score = excluded.score, tries = public.answers.tries + 1, updated_at = now();
      end if;
    end loop;
  end if;
  return public._payload(sid);
end $$;

-- ---------- funções do PROFESSOR (exigem login) ----------
create or replace function public.teacher_check()
returns boolean language sql security definer set search_path = public as $$ select public._is_teacher() $$;

create or replace function public.teacher_overview()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  return jsonb_build_object(
    'students', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'class', s.class, 'created_at', s.created_at,
        'results', (select coalesce(jsonb_agg(jsonb_build_object('phase',r.phase,'pct',r.pct,'stars',r.stars,'tries',r.tries,'at',r.updated_at)), '[]'::jsonb)
                      from public.results r where r.student_id = s.id)
      ) order by s.class, s.name), '[]'::jsonb) from public.students s),
    'closed', (select coalesce(jsonb_agg(phase), '[]'::jsonb) from public.closed_phases));
end $$;

create or replace function public.teacher_questions(p_class text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('qid', x.qid, 'n', x.n, 'avg', x.av) order by x.av), '[]'::jsonb)
            from (select a.qid, count(*) n, round(avg(a.score)::numeric, 3) av
                    from public.answers a join public.students s on s.id = a.student_id
                   where p_class is null or p_class = '' or lower(s.class) = lower(p_class)
                   group by a.qid) x);
end $$;

create or replace function public.teacher_set_phase(p_phase int, p_open boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  if p_open then delete from public.closed_phases where phase = p_phase;
  else insert into public.closed_phases(phase) values (p_phase) on conflict do nothing; end if;
end $$;

create or replace function public.teacher_reset_pin(p_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then raise exception 'O PIN deve ter 4 números'; end if;
  update public.students set pin_hash = crypt(p_pin, gen_salt('bf')), fails = 0, locked_until = null where id = p_id;
end $$;

create or replace function public.teacher_delete_student(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  delete from public.students where id = p_id;
end $$;

-- ---------- permissões ----------
revoke all on function public._auth_student(text,text,text), public._payload(uuid), public._is_teacher() from public, anon, authenticated;
revoke all on function public.student_signup(text,text,text), public.student_login(text,text,text),
  public.student_save(text,text,text,int,int,jsonb), public.teacher_check(), public.teacher_overview(),
  public.teacher_questions(text), public.teacher_set_phase(int,boolean), public.teacher_reset_pin(uuid,text),
  public.teacher_delete_student(uuid) from public;
grant execute on function public.student_signup(text,text,text), public.student_login(text,text,text),
  public.student_save(text,text,text,int,int,jsonb) to anon, authenticated;
grant execute on function public.teacher_check(), public.teacher_overview(), public.teacher_questions(text),
  public.teacher_set_phase(int,boolean), public.teacher_reset_pin(uuid,text), public.teacher_delete_student(uuid) to authenticated;

-- =====================================================================
--  DEPOIS de criar seu usuário em Authentication > Users, rode UMA vez
--  (troque pelo seu e-mail) para virar PROFESSOR:
--
--  insert into public.teachers(user_id) select id from auth.users where email = 'seu@email.com';
-- =====================================================================
