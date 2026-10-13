-- Verification harness for db/schema.sql and db/seed.sql.
--
-- Stands up just enough of Supabase (the auth schema, auth.uid(), the anon and
-- authenticated roles, and Supabase's grant-all-by-default on new public
-- tables) to run the real db/schema.sql and db/seed.sql, then checks the draw
-- rules and the access rules as an actual signed-in participant.
--
-- Supabase's defaults are replicated BEFORE schema.sql runs, so the revokes in
-- schema.sql are tested as doing something rather than passing because the
-- grant was never there.
--
-- Prints aggregates and booleans only. It never prints a pair, and never
-- prints a participant id.
--
--
-- DO NOT RUN THIS AGAINST THE REAL PROJECT. It deletes from both tables
-- (checks 11 and 12), which would destroy a completed draw. Run it only
-- against a throwaway database.
--
--
-- How to run it, from the repo root:
--
--   docker run -d --name ss-pg -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=ss postgres:16
--   docker cp . ss-pg:/work
--   docker exec -w /work ss-pg psql -U postgres -d ss -f db/test/harness.sql
--   docker rm -f ss-pg
--
-- Expect exit code 0, twelve PASS notices and no FAIL. Each check states its
-- expected values in a trailing comment. Paths are relative to the repo root,
-- so run it from there, not from db/test.
--
-- Two things stop this being run by accident against live data: the guard
-- below, and the fact that the Supabase SQL editor cannot execute psql's
-- \set and \i meta-commands at all.

\set ON_ERROR_STOP on

-- The guard. The hazard is deleting real rows, so the condition is exactly
-- that: refuse the moment there is anything here worth losing. Deliberately
-- not a check for Supabase internals, which would rot as the platform changes,
-- and deliberately first, so it does not depend on the order of what follows.
-- The table usually does not exist yet, so the row check has to go through
-- EXECUTE: plpgsql plans a statement as a whole, and naming a missing relation
-- in a plain expression fails at plan time even when the AND would have
-- short-circuited past it.
do $$
declare
  v_occupied boolean;
begin
  if to_regclass('public.participants') is null then
    return;
  end if;
  execute 'select exists (select 1 from public.participants)' into v_occupied;
  if v_occupied then
    raise exception
      'refusing to run: public.participants already has rows. This harness deletes from both tables; run it only against a throwaway database.';
  end if;
end $$;

create role anon nologin;
create role authenticated nologin;

create schema auth;
create table auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text unique
);

-- Stands in for Supabase's auth.uid(), which reads the caller's JWT. Here the
-- "signed-in user" is whatever test.uid is set to.
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid
$$;

grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;

-- Supabase's default privileges grant ALL on new public tables to anon and
-- authenticated. Replicate that so the revokes in schema.sql are actually
-- tested as doing something, rather than passing because the grant was never
-- there in the first place.
alter default privileges in schema public grant all on tables to anon, authenticated;

\echo '== applying db/schema.sql =='
\i db/schema.sql

\echo '== seeding 7 auth users and applying db/seed.sql =='
insert into auth.users (email) values
  ('agneta@secretsanta.local'),
  ('christer@secretsanta.local'),
  ('christofer@secretsanta.local'),
  ('tobias@secretsanta.local'),
  ('amelia@secretsanta.local'),
  ('sebastian@secretsanta.local'),
  ('ellie@secretsanta.local');

\i db/seed.sql

\echo '== names derived by seed.sql =='
select string_agg(name, ', ' order by name) as names from public.participants;

-- Remember two ids for later, without ever printing them.
create table test_ids as
select
  (select id from public.participants where name = 'Sebastian') as admin_id,
  (select id from public.participants where name = 'Agneta')    as plain_id;


\echo ''
\echo '== 1. a non-admin cannot run the draw =='
set role authenticated;
select set_config('test.uid', (select plain_id::text from test_ids), false) is not null as ok;
do $$
begin
  perform public.run_draw();
  raise exception 'FAIL: non-admin was allowed to run the draw';
exception
  when sqlstate 'P0001' then
    if sqlerrm = 'not authorised to run the draw' then
      raise notice 'PASS: non-admin refused (%)', sqlerrm;
    else
      raise exception 'FAIL: wrong error for non-admin: %', sqlerrm;
    end if;
end $$;
reset role;


\echo ''
\echo '== 2. the admin can run the draw, and it returns a count =='
set role authenticated;
select set_config('test.uid', (select admin_id::text from test_ids), false) is not null as ok;
select public.run_draw() as assignments_written;
reset role;


\echo ''
\echo '== 3. the draw is one valid ring =='
select
  (select count(*) from public.assignments)                              as rows_written,
  (select count(*) from public.assignments where giver_id = receiver_id) as self_pairs,
  (select count(distinct giver_id)    from public.assignments)           as distinct_givers,
  (select count(distinct receiver_id) from public.assignments)           as distinct_receivers,
  (select count(*) from public.participants p
     where not exists (select 1 from public.assignments a where a.giver_id = p.id))    as nobody_to_give_to,
  (select count(*) from public.participants p
     where not exists (select 1 from public.assignments a where a.receiver_id = p.id)) as nobody_giving_to_them;
-- expect: 7, 0, 7, 7, 0, 0

-- A single cycle through all 7, rather than e.g. a 3-cycle plus a 4-cycle.
with recursive walk as (
  select a.receiver_id as node, 1 as depth
  from public.assignments a
  where a.giver_id = (select giver_id from public.assignments order by giver_id limit 1)
  union all
  select a.receiver_id, w.depth + 1
  from walk w
  join public.assignments a on a.giver_id = w.node
  where w.depth < 50
)
select min(depth) as cycle_length
from walk
where node = (select giver_id from public.assignments order by giver_id limit 1);
-- expect: 7


\echo ''
\echo '== 4. a second draw is refused unless p_redraw is true =='
set role authenticated;
select set_config('test.uid', (select admin_id::text from test_ids), false) is not null as ok;
do $$
begin
  perform public.run_draw();
  raise exception 'FAIL: a second draw was allowed to overwrite the first';
exception
  when sqlstate 'P0001' then
    if sqlerrm = 'a draw already exists' then
      raise notice 'PASS: overwrite refused (%)', sqlerrm;
    else
      raise exception 'FAIL: wrong error for second draw: %', sqlerrm;
    end if;
end $$;
select public.run_draw(true) as redraw_wrote;
reset role;

\echo '== the redraw is still one valid ring =='
select
  (select count(*) from public.assignments)                              as rows_written,
  (select count(*) from public.assignments where giver_id = receiver_id) as self_pairs,
  (select count(distinct receiver_id) from public.assignments)           as distinct_receivers;
-- expect: 7, 0, 7


\echo ''
\echo '== 5. what a signed-in participant can read =='
set role authenticated;
select set_config('test.uid', (select plain_id::text from test_ids), false) is not null as ok;

select count(*) as participant_rows_visible from public.participants;  -- expect 2 (self + giftee)
select count(*) as assignment_rows_visible  from public.assignments;   -- expect 1 (own row only)
select count(*) filter (where id = auth.uid()) as own_row,
       count(*) filter (where id <> auth.uid()) as other_rows
from public.participants;
-- expect: 1, 1

select public.draw_done() as draw_done;  -- expect true


\echo ''
\echo '== 6. a participant cannot see a third person =='
reset role;
create table test_third as
select id from public.participants
where name not in ('Agneta')
  and id <> (select receiver_id from public.assignments
             where giver_id = (select plain_id from test_ids))
limit 1;
set role authenticated;
select set_config('test.uid', (select plain_id::text from test_ids), false) is not null as ok;
select count(*) as third_person_rows_visible
from public.participants
where id = (select id from test_third);
-- expect: 0

select count(*) as someone_elses_assignment_visible
from public.assignments
where giver_id <> auth.uid();
-- expect: 0


\echo ''
\echo '== 7. a participant can update their own wishlist =='
update public.participants set wishlist = 'a very large cheese' where id = auth.uid();
select wishlist = 'a very large cheese' as own_wishlist_saved,
       updated_at > now() - interval '1 minute' as updated_at_moved
from public.participants where id = auth.uid();
-- expect: t, t


\echo ''
\echo '== 8. a participant cannot promote themselves =='
do $$
begin
  update public.participants set is_admin = true where id = auth.uid();
  raise exception 'FAIL: participant promoted themselves to admin';
exception
  when insufficient_privilege then
    raise notice 'PASS: is_admin refused (%)', sqlerrm;
end $$;

\echo '== ...or rename themselves =='
do $$
begin
  update public.participants set name = 'Santa' where id = auth.uid();
  raise exception 'FAIL: participant changed their own name';
exception
  when insufficient_privilege then
    raise notice 'PASS: name refused (%)', sqlerrm;
end $$;

\echo '== ...or edit anyone else =='
select count(*) as rows_i_could_update from public.participants where id <> auth.uid();
update public.participants set wishlist = 'tampered' where id <> auth.uid();
-- expect: UPDATE 0


\echo ''
\echo '== 9. the browser has no write rights on assignments at all =='
do $$
begin
  insert into public.assignments (giver_id, receiver_id)
  values (auth.uid(), (select id from test_third));
  raise exception 'FAIL: participant inserted an assignment';
exception
  when insufficient_privilege then raise notice 'PASS: insert refused (%)', sqlerrm;
  when others then raise exception 'FAIL: insert blocked by the wrong thing: % / %', sqlstate, sqlerrm;
end $$;

do $$
begin
  update public.assignments set receiver_id = auth.uid();
  raise exception 'FAIL: participant updated an assignment';
exception
  when insufficient_privilege then raise notice 'PASS: update refused (%)', sqlerrm;
  when others then raise exception 'FAIL: update blocked by the wrong thing: % / %', sqlstate, sqlerrm;
end $$;

do $$
begin
  delete from public.assignments;
  raise exception 'FAIL: participant deleted assignments';
exception
  when insufficient_privilege then raise notice 'PASS: delete refused (%)', sqlerrm;
  when others then raise exception 'FAIL: delete blocked by the wrong thing: % / %', sqlstate, sqlerrm;
end $$;

select count(*) as assignments_still_there_after_all_that from public.assignments;
-- expect: 7 (read as owner below, this read is the participant's own row only)
reset role;
select count(*) as assignments_intact from public.assignments;
-- expect: 7


\echo ''
\echo '== 10. a signed-out visitor gets nothing =='
set role anon;
do $$
begin
  perform count(*) from public.participants;
  raise exception 'FAIL: anon read participants';
exception
  when insufficient_privilege then raise notice 'PASS: anon refused on participants (%)', sqlerrm;
end $$;

do $$
begin
  perform count(*) from public.assignments;
  raise exception 'FAIL: anon read assignments';
exception
  when insufficient_privilege then raise notice 'PASS: anon refused on assignments (%)', sqlerrm;
end $$;

do $$
begin
  perform public.run_draw();
  raise exception 'FAIL: anon ran the draw';
exception
  when insufficient_privilege then raise notice 'PASS: anon refused on run_draw (%)', sqlerrm;
end $$;

do $$
begin
  perform public.draw_done();
  raise exception 'FAIL: anon called draw_done';
exception
  when insufficient_privilege then raise notice 'PASS: anon refused on draw_done (%)', sqlerrm;
end $$;
reset role;


\echo ''
\echo '== 11. seed.sql is safe to run twice =='
\i db/seed.sql


\echo ''
\echo '== 12. fewer than 3 participants is refused =='
-- Keep 2 people and make one of them the admin. The admin id is computed while
-- still unrestricted: reading it from inside the authenticated role would be
-- filtered by the very policies under test.
create table keep as select id from public.participants order by id limit 2;
delete from public.assignments;
delete from public.participants where id not in (select id from keep);
-- Exactly one admin among the two survivors. Sebastian may well be one of
-- them, so this clears the flag everywhere in the same statement.
update public.participants
  set is_admin = (id = (select id from keep order by id limit 1));
create table tiny_admin as select id from public.participants where is_admin;

select count(*) as people_left,
       count(*) filter (where is_admin) as admins
from public.participants;
-- expect: 2, 1

set role authenticated;
select set_config('test.uid', (select id::text from tiny_admin), false) is not null as ok;
do $$
begin
  perform public.run_draw();
  raise exception 'FAIL: a 2-person draw was allowed';
exception
  when sqlstate 'P0001' then
    if sqlerrm = 'need at least 3 participants' then
      raise notice 'PASS: too-few-participants refused (%)', sqlerrm;
    else
      raise exception 'FAIL: wrong error: %', sqlerrm;
    end if;
end $$;
reset role;


\echo ''
\echo '== 13. the privilege surface, stated plainly =='
select
  has_table_privilege('anon','public.participants','select')          as anon_sel_participants,
  has_table_privilege('anon','public.assignments','select')           as anon_sel_assignments,
  has_table_privilege('authenticated','public.participants','select') as auth_sel_participants,
  has_table_privilege('authenticated','public.participants','insert') as auth_ins_participants,
  has_table_privilege('authenticated','public.participants','delete') as auth_del_participants;
-- expect: f, f, t, f, f

select
  has_table_privilege('authenticated','public.assignments','select') as auth_sel_assignments,
  has_table_privilege('authenticated','public.assignments','insert') as auth_ins_assignments,
  has_table_privilege('authenticated','public.assignments','update') as auth_upd_assignments,
  has_table_privilege('authenticated','public.assignments','delete') as auth_del_assignments;
-- expect: t, f, f, f

select
  has_column_privilege('authenticated','public.participants','wishlist','update')   as upd_wishlist,
  has_column_privilege('authenticated','public.participants','is_admin','update')   as upd_is_admin,
  has_column_privilege('authenticated','public.participants','name','update')       as upd_name,
  has_column_privilege('authenticated','public.participants','id','update')         as upd_id,
  has_column_privilege('authenticated','public.participants','updated_at','update') as upd_updated_at;
-- expect: t, f, f, f, f

\echo '== RLS is on for both tables =='
select relname, relrowsecurity as rls_enabled
from pg_class
where oid in ('public.participants'::regclass, 'public.assignments'::regclass)
order by relname;
-- expect: both t

\echo '== the policies that exist =='
select tablename, policyname, cmd
from pg_policies
where schemaname = 'public'
order by tablename, policyname;

\echo ''
\echo '== all checks finished =='
