-- =====================================================================
--  Progresso dos JOGOS salvo por usuário (nuvem) + gestão de alunos
--  Rode UMA vez no SQL Editor (depois do supabase.sql). Pode repetir.
-- =====================================================================
create table if not exists public.progress(
  student_id uuid not null references public.students(id) on delete cascade,
  key text not null check (key like 'fabricaRele\_%' and char_length(key) <= 60),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (student_id, key)
);
alter table public.progress enable row level security;
revoke all on public.progress from anon, authenticated;

-- ---------- ALUNO ----------
create or replace function public.progress_load(p_name text, p_class text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb;
begin
  a := public._auth_student(p_name, p_class, p_pin);
  if a ? 'error' then return a; end if;
  return jsonb_build_object('ok', true, 'name', a->>'name', 'class', a->>'class',
    'data', (select coalesce(jsonb_object_agg(key, data), '{}'::jsonb) from public.progress where student_id = (a->>'id')::uuid));
end $$;

create or replace function public.progress_save(p_name text, p_class text, p_pin text, p_key text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb;
begin
  if p_key is null or p_key not like 'fabricaRele\_%' or char_length(p_key) > 60 then
    return jsonb_build_object('error','Chave inválida.'); end if;
  if p_data is null or pg_column_size(p_data) > 60000 then
    return jsonb_build_object('error','Dados grandes demais.'); end if;
  a := public._auth_student(p_name, p_class, p_pin);
  if a ? 'error' then return a; end if;
  insert into public.progress(student_id, key, data, updated_at)
    values ((a->>'id')::uuid, p_key, p_data, now())
    on conflict (student_id, key) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- ---------- PROFESSOR ----------
create or replace function public.teacher_progress()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('student_id', student_id, 'key', key,
            'stars', (select coalesce(sum(v::int),0) from jsonb_each_text(coalesce(data->'stars','{}'::jsonb)) e(k,v) where v ~ '^[0-9]+$'),
            'done', (select count(*) from jsonb_each_text(coalesce(data->'stars','{}'::jsonb)) e(k,v) where v ~ '^[1-9][0-9]*$'),
            'at', updated_at)), '[]'::jsonb) from public.progress);
end $$;

create or replace function public.teacher_progress_reset(p_id uuid, p_key text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  delete from public.progress where student_id = p_id and (p_key is null or key = p_key);
end $$;

create or replace function public.teacher_update_student(p_id uuid, p_name text, p_class text)
returns void language plpgsql security definer set search_path = public as $$
declare n text; c text;
begin
  if not public._is_teacher() then raise exception 'Acesso negado'; end if;
  n := regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g'); c := btrim(coalesce(p_class,''));
  if char_length(n) < 2 or char_length(n) > 60 or char_length(c) < 1 or char_length(c) > 30 then
    raise exception 'Nome (2 a 60) e turma (1 a 30) inválidos'; end if;
  if exists (select 1 from public.students where id <> p_id and lower(name)=lower(n) and lower(class)=lower(c)) then
    raise exception 'Já existe esse nome nessa turma'; end if;
  update public.students set name = n, class = c where id = p_id;
end $$;

revoke all on function public.progress_load(text,text,text), public.progress_save(text,text,text,text,jsonb),
  public.teacher_progress(), public.teacher_progress_reset(uuid,text), public.teacher_update_student(uuid,text,text) from public;
grant execute on function public.progress_load(text,text,text), public.progress_save(text,text,text,text,jsonb) to anon, authenticated;
grant execute on function public.teacher_progress(), public.teacher_progress_reset(uuid,text), public.teacher_update_student(uuid,text,text) to authenticated;
