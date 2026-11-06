-- Tourism Quest: Supabase setup
-- Run this whole script in Supabase Dashboard > SQL Editor.
-- Then enable Anonymous Sign-Ins in Authentication > Providers.

create extension if not exists pgcrypto;

create table if not exists public.tq_classes (
  id uuid primary key default gen_random_uuid(),
  class_name text not null,
  class_code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.tq_sessions (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.tq_classes(id) on delete cascade,
  pin text not null unique,
  title text not null,
  mode text not null check (mode in ('individual','group')),
  status text not null default 'waiting' check (status in ('waiting','question','finished','closed')),
  total_questions integer not null check (total_questions between 1 and 30),
  seconds_per_question integer not null check (seconds_per_question between 5 and 120),
  current_index integer not null default -1,
  started_at timestamptz,
  host_uid uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.tq_participants (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.tq_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  team_name text,
  participant_key text not null,
  score integer not null default 0,
  correct_count integer not null default 0,
  answered_count integer not null default 0,
  joined_at timestamptz not null default now(),
  unique(session_id,user_id)
);

create table if not exists public.tq_session_questions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.tq_sessions(id) on delete cascade,
  question_index integer not null,
  level text not null,
  prompt text not null,
  options jsonb not null,
  correct_option text not null check (correct_option in ('A','B','C','D')),
  explanation text not null,
  topic text,
  unique(session_id,question_index)
);

create table if not exists public.tq_answers (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.tq_sessions(id) on delete cascade,
  participant_id uuid not null references public.tq_participants(id) on delete cascade,
  question_index integer not null,
  selected_option integer not null check (selected_option between 0 and 3),
  is_correct boolean not null,
  points_awarded integer not null default 0,
  created_at timestamptz not null default now(),
  unique(participant_id,question_index)
);

create index if not exists tq_sessions_class_id_idx on public.tq_sessions(class_id);
create index if not exists tq_participants_session_id_idx on public.tq_participants(session_id);
create index if not exists tq_answers_session_id_idx on public.tq_answers(session_id);

alter table public.tq_classes enable row level security;
alter table public.tq_sessions enable row level security;
alter table public.tq_participants enable row level security;
alter table public.tq_session_questions enable row level security;
alter table public.tq_answers enable row level security;

-- Classes: a lecturer can see and create only classes owned by their auth identity.
drop policy if exists "class owner read" on public.tq_classes;
create policy "class owner read" on public.tq_classes for select to authenticated using (owner_id = auth.uid());
drop policy if exists "class owner insert" on public.tq_classes;
create policy "class owner insert" on public.tq_classes for insert to authenticated with check (owner_id = auth.uid());

-- Sessions: host can manage; enrolled participants can read their own session metadata.
drop policy if exists "host manages sessions" on public.tq_sessions;
create policy "host manages sessions" on public.tq_sessions for all to authenticated
using (host_uid = auth.uid()) with check (host_uid = auth.uid());
drop policy if exists "participant reads session" on public.tq_sessions;
create policy "participant reads session" on public.tq_sessions for select to authenticated
using (exists(select 1 from public.tq_participants p where p.session_id=id and p.user_id=auth.uid()));

-- SECURITY DEFINER helper avoids recursive RLS when checking session membership.
create or replace function public.tq_is_session_member(p_session_id uuid)
returns boolean language sql stable security definer set search_path=public
as $$
 select exists(select 1 from public.tq_participants p where p.session_id=p_session_id and p.user_id=auth.uid())
     or exists(select 1 from public.tq_sessions s where s.id=p_session_id and s.host_uid=auth.uid());
$$;
grant execute on function public.tq_is_session_member(uuid) to authenticated;

drop policy if exists "session members read class" on public.tq_classes;
create policy "session members read class" on public.tq_classes for select to authenticated
using (owner_id=auth.uid() or exists(
  select 1 from public.tq_sessions s where s.class_id=id and public.tq_is_session_member(s.id)
));

-- Participants: host and members of that session can read leaderboard.
drop policy if exists "session members read participants" on public.tq_participants;
create policy "session members read participants" on public.tq_participants for select to authenticated
using (public.tq_is_session_member(session_id));
-- No direct participant insert/update from browser; joining and scoring are RPC-only.

-- Question answer keys are private: only the lecturer can select/insert them.
drop policy if exists "host manages session questions" on public.tq_session_questions;
create policy "host manages session questions" on public.tq_session_questions for all to authenticated
using (exists(select 1 from public.tq_sessions s where s.id=session_id and s.host_uid=auth.uid()))
with check (exists(select 1 from public.tq_sessions s where s.id=session_id and s.host_uid=auth.uid()));

-- Answers are not directly readable/writable by students; score updates go through RPC.
drop policy if exists "host reads answers" on public.tq_answers;
create policy "host reads answers" on public.tq_answers for select to authenticated
using (exists(select 1 from public.tq_sessions s where s.id=session_id and s.host_uid=auth.uid()));

create or replace function public.tq_join_session(p_pin text, p_display_name text, p_team_name text default null)
returns table(session_id uuid, participant_id uuid, team_name text, mode text, class_name text, title text)
language plpgsql security definer set search_path=public
as $$
declare s public.tq_sessions%rowtype; c public.tq_classes%rowtype; p public.tq_participants%rowtype; k text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into s from public.tq_sessions where pin=p_pin and status in ('waiting','question');
 if not found then raise exception 'Room not found or closed'; end if;
 select * into c from public.tq_classes where id=s.class_id;
 if s.mode='group' and coalesce(trim(p_team_name),'')='' then raise exception 'Team name is required in group mode'; end if;
 k := case when s.mode='group' then lower(regexp_replace(trim(p_team_name),'[^a-zA-Z0-9]+','-','g')) else auth.uid()::text end;
 insert into public.tq_participants(session_id,user_id,display_name,team_name,participant_key)
 values(s.id,auth.uid(),left(trim(p_display_name),60),case when s.mode='group' then left(trim(p_team_name),60) else null end,k)
 on conflict(session_id,user_id) do update set display_name=excluded.display_name,team_name=excluded.team_name,participant_key=excluded.participant_key
 returning * into p;
 return query select s.id,p.id,p.team_name,s.mode,c.class_name,s.title;
end $$;

create or replace function public.tq_get_question(p_session_id uuid,p_question_index integer)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare q public.tq_session_questions%rowtype; s public.tq_sessions%rowtype; result jsonb;
begin
 select * into s from public.tq_sessions where id=p_session_id;
 if not found or s.status<>'question' or s.current_index<>p_question_index then raise exception 'Question is not active'; end if;
 if not exists(select 1 from public.tq_participants where session_id=p_session_id and user_id=auth.uid())
    and s.host_uid<>auth.uid() then raise exception 'Not a member of this session'; end if;
 select * into q from public.tq_session_questions where session_id=p_session_id and question_index=p_question_index;
 if not found then raise exception 'Question not found'; end if;
 result := jsonb_build_object('level',q.level,'prompt',q.prompt,'options',q.options);
 if exists(select 1 from public.tq_answers a join public.tq_participants p on p.id=a.participant_id
           where a.session_id=p_session_id and a.question_index=p_question_index and p.user_id=auth.uid()) then
   result := result || jsonb_build_object('correct_index',case q.correct_option when 'A' then 0 when 'B' then 1 when 'C' then 2 when 'D' then 3 end);
 end if;
 return result;
end $$;

create or replace function public.tq_submit_answer(p_session_id uuid,p_question_index integer,p_selected_option integer)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare s public.tq_sessions%rowtype; q public.tq_session_questions%rowtype; p public.tq_participants%rowtype;
        ok boolean; pts integer; correct_idx integer;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_selected_option not between 0 and 3 then raise exception 'Invalid answer'; end if;
 select * into s from public.tq_sessions where id=p_session_id for update;
 if not found or s.status<>'question' or s.current_index<>p_question_index then raise exception 'This question is no longer active'; end if;
 if s.started_at is null or now()>s.started_at + make_interval(secs=>s.seconds_per_question) then raise exception 'Time is up'; end if;
 select * into p from public.tq_participants where session_id=p_session_id and user_id=auth.uid() for update;
 if not found then raise exception 'You are not registered in this session'; end if;
 select * into q from public.tq_session_questions where session_id=p_session_id and question_index=p_question_index;
 correct_idx := case q.correct_option when 'A' then 0 when 'B' then 1 when 'C' then 2 when 'D' then 3 end;
 ok := p_selected_option=correct_idx;
 pts := case when ok then 100 + greatest(0, floor(extract(epoch from (s.started_at + make_interval(secs=>s.seconds_per_question)-now())))::integer)*10 else 0 end;
 insert into public.tq_answers(session_id,participant_id,question_index,selected_option,is_correct,points_awarded)
 values(p_session_id,p.id,p_question_index,p_selected_option,ok,pts);
 update public.tq_participants set score=score+pts,correct_count=correct_count+(case when ok then 1 else 0 end),answered_count=answered_count+1 where id=p.id;
 return jsonb_build_object('is_correct',ok,'points_awarded',pts,'explanation',q.explanation);
exception when unique_violation then
 raise exception 'You have already answered this question';
end $$;

grant execute on function public.tq_join_session(text,text,text) to authenticated;
grant execute on function public.tq_get_question(uuid,integer) to authenticated;
grant execute on function public.tq_submit_answer(uuid,integer,integer) to authenticated;

-- Enable Postgres Changes for the two tables the client watches.
do $$ begin
  alter publication supabase_realtime add table public.tq_sessions;
exception when duplicate_object then null;
when undefined_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.tq_participants;
exception when duplicate_object then null;
when undefined_object then null;
end $$;
