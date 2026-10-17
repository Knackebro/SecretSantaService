-- Secret Santa — database schema, access rules and the draw.
--
-- Apply this once to a fresh Supabase project:
--   Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
--
-- Then apply every file in db/migrations in number order, the same way. They
-- are the changes made after the first version of this file. A project that is
-- already running the site needs only the migrations it has not had yet.
--
-- After that, create the 7 auth users (Authentication -> Users -> Add user,
-- "Auto Confirm User" checked) and then apply db/seed.sql.
--
-- Everything that keeps the draw secret is in this file. The JavaScript in the
-- site is a convenience; it is not a security boundary. A participant who opens
-- the browser console and calls the REST API directly is still held to exactly
-- the rules below.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- One row per participant, linked to their login.
create table public.participants (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null unique,            -- 'Agneta', 'Christer', ...
  wishlist    text not null default '',
  is_admin    boolean not null default false,  -- true for Sebastian only
  updated_at  timestamptz not null default now()
);

-- The draw: one row per giver.
create table public.assignments (
  giver_id    uuid primary key references public.participants(id) on delete cascade,
  receiver_id uuid not null unique references public.participants(id) on delete cascade,
  check (giver_id <> receiver_id)
);

-- The three constraints above are what make the draw rules automatic:
--   giver_id is the primary key      -> nobody gives twice
--   receiver_id is unique            -> nobody is drawn twice
--   check (giver_id <> receiver_id)  -> nobody draws themselves
-- A draw that broke any of those rules cannot be written at all.

-- Keep updated_at honest. The browser is not granted update on this column
-- (see the grants below), so the only way it can move is from here.
create or replace function public.participants_touch_updated_at()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger participants_touch_updated_at
  before update on public.participants
  for each row execute function public.participants_touch_updated_at();

-- ---------------------------------------------------------------------------
-- Column privileges
-- ---------------------------------------------------------------------------
-- Supabase's default privileges grant ALL on new public tables to anon and
-- authenticated, so these revokes are not optional. Stating the whole surface
-- here means the permissions are a property of this file rather than something
-- inherited from the platform's defaults.

-- Signed-out visitors get nothing at all.
revoke all on table public.participants from anon, authenticated;
revoke all on table public.assignments  from anon, authenticated;

-- A participant may read participant rows (which ones is decided by the policy
-- below) and may write exactly one column, on exactly their own row.
grant select           on table public.participants to authenticated;
grant update (wishlist) on table public.participants to authenticated;

-- A participant may read assignment rows (again, which ones is the policy's
-- call) and may never insert, update or delete one. The only writer is
-- run_draw() below, which runs as the definer and bypasses this.
grant select on table public.assignments to authenticated;

-- Because the update grant is column-scoped, a participant cannot promote
-- themselves: UPDATE participants SET is_admin = true fails with
-- "permission denied for column is_admin" even on their own row.

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
-- With RLS on and no permissive policy for a command, that command is denied.
-- There is deliberately no insert, update or delete policy on assignments.

alter table public.participants enable row level security;
alter table public.assignments  enable row level security;

-- Who is my giftee? Answered by a definer function rather than an inline
-- subquery over assignments, so the participants policy does not depend on the
-- assignments policy happening to grant the same rows. See the note at the
-- bottom of this file.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create or replace function private.my_giftee_id()
returns uuid language sql security definer set search_path = '' stable as $$
  select receiver_id from public.assignments where giver_id = auth.uid()
$$;

revoke execute on function private.my_giftee_id() from public;
grant  execute on function private.my_giftee_id() to authenticated;

-- You can read your own draw and nothing else.
create policy "assignments own row" on public.assignments for select
  using (giver_id = auth.uid());

-- You can read your own row and your giftee's row.
-- Your giftee's row holds their name and their wishlist and nothing about their
-- own draw, because the draw lives in the other table.
create policy "participants self or giftee" on public.participants for select
  using (id = auth.uid() or id = private.my_giftee_id());

-- You can edit your own wishlist. Which column is settled by the grant above.
create policy "update own wishlist" on public.participants for update
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- The draw
-- ---------------------------------------------------------------------------
-- The whole draw happens in here, so the pairs never travel to the browser and
-- never reach a log. The admin presses a button and learns one number.

create or replace function public.run_draw(p_redraw boolean default false)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_written  integer;
  v_people   integer;
  v_existing integer;
begin
  -- Only an admin participant may run the draw. This check lives here and not
  -- in the JavaScript: a non-admin calling run_draw() from the browser console
  -- gets "not authorised to run the draw".
  if not exists (
    select 1 from public.participants
    where id = auth.uid() and is_admin
  ) then
    raise exception 'not authorised to run the draw';
  end if;

  select count(*) into v_existing from public.assignments;
  if v_existing > 0 then
    if not p_redraw then
      raise exception 'a draw already exists';
    end if;
    delete from public.assignments;
  end if;

  select count(*) into v_people from public.participants;
  if v_people < 3 then
    raise exception 'need at least 3 participants';
  end if;

  -- One shuffled ring: each person gives to the next, the last gives to the
  -- first. A ring is automatically a valid draw -- everyone gives once,
  -- everyone receives once, nobody draws themselves. No retry loop and no
  -- rejection sampling.
  --
  -- The ring length comes from a window function inside the CTE rather than
  -- from v_people, so the row numbering and the modulus are read from the same
  -- snapshot and cannot disagree.
  --
  -- "as materialized" is deliberate. The CTE is referenced twice and contains
  -- random(), so Postgres would materialize it anyway, but saying so makes it
  -- immune to planner changes: without it there is a theoretical path where the
  -- two references shuffle differently and the insert produces garbage.
  with shuffled as materialized (
    select id,
           row_number() over (order by random()) as rn,
           count(*)     over ()                  as n
    from public.participants
  )
  insert into public.assignments (giver_id, receiver_id)
  select g.id, r.id
  from shuffled g
  join shuffled r on r.rn = (g.rn % g.n) + 1;

  -- Report what was actually written, not what we expected to write.
  get diagnostics v_written = row_count;

  -- The whole function body is one transaction. Any failure above -- including
  -- a constraint violation -- leaves no rows behind.
  return v_written;
end;
$$;

revoke execute on function public.run_draw(boolean) from public;
grant  execute on function public.run_draw(boolean) to authenticated;

-- Lets the page show whether a draw has happened without revealing any pair.
create or replace function public.draw_done()
returns boolean language sql security definer set search_path = '' stable as $$
  select exists (select 1 from public.assignments)
$$;

revoke execute on function public.draw_done() from public;
grant  execute on function public.draw_done() to authenticated;

-- ---------------------------------------------------------------------------
-- Why my_giftee_id() is a function
-- ---------------------------------------------------------------------------
-- The shorter form of the participants policy inlines the lookup:
--
--   using (id = auth.uid()
--          or id in (select receiver_id from assignments where giver_id = auth.uid()))
--
-- That is correct today, but only because the subquery's filter happens to be
-- the same condition the assignments policy already grants the caller. Edit the
-- assignments policy later and this one changes meaning silently, which is the
-- worst way for an access rule to break. The definer function states the
-- intent once, is unaffected by policy edits, and avoids a per-row subquery.
