-- Verification harness for db/schema.sql, db/migrations and db/seed.sql.
--
-- Stands up just enough of Supabase (the auth schema, auth.uid(), the anon and
-- authenticated roles, and Supabase's grant-all-by-default on new public
-- tables) to run the real db/schema.sql, the real migrations and the real
-- db/seed.sql, then checks the draw rules, the gift-suggestion rules and the
-- access rules as an actual signed-in participant.
--
-- Supabase's defaults are replicated BEFORE schema.sql runs, so the revokes in
-- schema.sql are tested as doing something rather than passing because the
-- grant was never there.
--
-- Prints aggregates and booleans only. It never prints a pair, and never
-- prints a participant id.
--
--
-- DO NOT RUN THIS AGAINST THE REAL PROJECT. It deletes participants and the
-- draw (checks 14 and 15), which would destroy a completed draw and every gift
-- suggestion with it. Run it only against a throwaway database.
--
--
-- How to run it, from the repo root:
--
--   docker run -d --name ss-pg -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=ss postgres:16
--   docker cp . ss-pg:/work
--   docker exec -w /work ss-pg psql -U postgres -d ss -f db/test/harness.sql
--   docker rm -f ss-pg
--
-- Expect exit code 0, 28 PASS notices and no FAIL. Each check states its
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

\echo '== applying db/migrations in order =='
\i db/migrations/0001-gift-suggestions.sql

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

do $$
begin
  perform count(*) from public.gift_suggestions;
  raise exception 'FAIL: anon read gift_suggestions';
exception
  when insufficient_privilege then raise notice 'PASS: anon refused on gift_suggestions (%)', sqlerrm;
end $$;

do $$
begin
  perform public.suggest_gift('Agneta', 'anon should not get this far');
  raise exception 'FAIL: anon left a gift suggestion';
exception
  when insufficient_privilege then raise notice 'PASS: anon refused on suggest_gift (%)', sqlerrm;
end $$;
reset role;


\echo ''
\echo '== 11. a gift suggestion reaches the Secret Santa and nobody else =='
-- Agneta leaves an idea for the third person -- somebody she is not giving to
-- and cannot even read. Then four people try to read it: the person it is
-- about, the person who wrote it, that person's Secret Santa, and the one
-- participant who is meant to see it.
reset role;
create table test_third_name as
select name from public.participants where id = (select id from test_third);

-- The third person's Secret Santa. Computed here, while unrestricted: reading
-- it from inside the authenticated role would be filtered by the very policies
-- under test. It is never printed.
create table test_third_santa as
select giver_id as id from public.assignments
where receiver_id = (select id from test_third);

-- test_third excludes Agneta's giftee, so Agneta is not this person's Secret
-- Santa. That is what makes the "the author cannot read it back" check below
-- mean something.
select (select id from test_third_santa) <> (select plain_id from test_ids)
  as author_is_not_the_santa;
-- expect: t

set role authenticated;
select set_config('test.uid', (select plain_id::text from test_ids), false) is not null as ok;
do $$
begin
  perform public.suggest_gift(
    (select name from test_third_name),
    'a cast iron pan',
    'https://example.com/pan'
  );
  raise notice 'PASS: a participant left an idea for somebody else';
end $$;

\echo '== the author cannot read back what she just wrote =='
select count(*) as rows_the_author_can_see
from public.gift_suggestions
where recipient_id = (select id from test_third);
-- expect: 0

\echo '== the person it is about cannot see it =='
select set_config('test.uid', (select id::text from test_third), false) is not null as ok;
select count(*) as rows_the_recipient_can_see from public.gift_suggestions;
-- expect: 0

\echo '== their Secret Santa sees it, and sees the text =='
select set_config('test.uid', (select id::text from test_third_santa), false) is not null as ok;
select count(*) as rows_the_santa_can_see,
       count(*) filter (where suggestion = 'a cast iron pan') as text_arrived,
       count(*) filter (where link = 'https://example.com/pan') as link_arrived
from public.gift_suggestions;
-- expect: 1, 1, 1

\echo '== ...but is not told who wrote it =='
do $$
begin
  perform submitter_id from public.gift_suggestions;
  raise exception 'FAIL: the Secret Santa read submitter_id';
exception
  when insufficient_privilege then raise notice 'PASS: submitter_id refused (%)', sqlerrm;
end $$;

\echo '== ...and is not told when =='
do $$
begin
  perform created_at from public.gift_suggestions;
  raise exception 'FAIL: the Secret Santa read created_at';
exception
  when insufficient_privilege then raise notice 'PASS: created_at refused (%)', sqlerrm;
end $$;
reset role;


\echo ''
\echo '== 12. the browser cannot write gift_suggestions directly =='
set role authenticated;
select set_config('test.uid', (select plain_id::text from test_ids), false) is not null as ok;

do $$
begin
  insert into public.gift_suggestions (recipient_id, submitter_id, suggestion)
  values ((select id from test_third), auth.uid(), 'written the wrong way');
  raise exception 'FAIL: participant inserted a suggestion directly';
exception
  when insufficient_privilege then raise notice 'PASS: direct insert refused (%)', sqlerrm;
  when others then raise exception 'FAIL: insert blocked by the wrong thing: % / %', sqlstate, sqlerrm;
end $$;

-- The point of this one: somebody who could update a row could rewrite a note
-- after their giftee read it, or point its link somewhere else.
do $$
begin
  update public.gift_suggestions set suggestion = 'tampered';
  raise exception 'FAIL: participant updated a suggestion';
exception
  when insufficient_privilege then raise notice 'PASS: direct update refused (%)', sqlerrm;
  when others then raise exception 'FAIL: update blocked by the wrong thing: % / %', sqlstate, sqlerrm;
end $$;

do $$
begin
  delete from public.gift_suggestions;
  raise exception 'FAIL: participant deleted suggestions';
exception
  when insufficient_privilege then raise notice 'PASS: direct delete refused (%)', sqlerrm;
  when others then raise exception 'FAIL: delete blocked by the wrong thing: % / %', sqlstate, sqlerrm;
end $$;
reset role;
select count(*) as suggestions_intact from public.gift_suggestions;
-- expect: 1


\echo ''
\echo '== 13. what suggest_gift refuses =='
set role authenticated;
select set_config('test.uid', (select plain_id::text from test_ids), false) is not null as ok;

-- Each case names the exact message, because these messages are what a person
-- reads on the page. A reworded message is a change to the site.
do $$
declare
  v_third text := (select name from test_third_name);
  v_cases text[][] := array[
    array['',        null,          'write something before you save it'],
    array['   ',     null,          'write something before you save it'],
    array['an idea', 'example.com', 'a link has to start with http:// or https://'],
    array['an idea', 'javascript:alert(1)', 'a link has to start with http:// or https://']
  ];
  v_case text[];
begin
  foreach v_case slice 1 in array v_cases loop
    begin
      perform public.suggest_gift(v_third, v_case[1], v_case[2]);
      raise exception 'FAIL: suggest_gift accepted %', coalesce(nullif(v_case[1], ''), '(empty)');
    exception
      when sqlstate 'P0001' then
        if sqlerrm = v_case[3] then
          raise notice 'PASS: refused (%)', sqlerrm;
        else
          raise exception 'FAIL: wrong error: % (wanted %)', sqlerrm, v_case[3];
        end if;
    end;
  end loop;
end $$;

\echo '== a suggestion longer than 500 characters =='
do $$
begin
  perform public.suggest_gift(
    (select name from test_third_name),
    repeat('x', 501)
  );
  raise exception 'FAIL: a 501-character suggestion was accepted';
exception
  when sqlstate 'P0001' then
    if sqlerrm = 'a suggestion has to be 500 characters or fewer' then
      raise notice 'PASS: too long refused (%)', sqlerrm;
    else
      raise exception 'FAIL: wrong error: %', sqlerrm;
    end if;
end $$;

\echo '== suggesting a gift for yourself =='
do $$
begin
  perform public.suggest_gift(
    (select name from public.participants where id = auth.uid()),
    'something for me'
  );
  raise exception 'FAIL: a participant suggested a gift for themselves';
exception
  when sqlstate 'P0001' then
    if sqlerrm like 'you cannot suggest a gift for yourself%' then
      raise notice 'PASS: self refused (%)', sqlerrm;
    else
      raise exception 'FAIL: wrong error: %', sqlerrm;
    end if;
end $$;

\echo '== a name that is not in the group =='
do $$
begin
  perform public.suggest_gift('Krampus', 'coal');
  raise exception 'FAIL: a suggestion was left for a name that does not exist';
exception
  when sqlstate 'P0001' then
    if sqlerrm = 'there is nobody called Krampus in the group' then
      raise notice 'PASS: unknown name refused (%)', sqlerrm;
    else
      raise exception 'FAIL: wrong error: %', sqlerrm;
    end if;
end $$;

\echo '== the sixth idea for the same person =='
-- One idea is already there from check 11, so four more reach the limit of 5.
-- These four are written in their own block, with no exception handler. A
-- plpgsql block that catches an exception rolls back everything it did, so
-- doing the inserts and the refusal together would throw the four rows away
-- and the count below would prove nothing.
do $$
declare
  v_third text := (select name from test_third_name);
begin
  for i in 2..5 loop
    perform public.suggest_gift(v_third, 'idea number ' || i);
  end loop;
end $$;

do $$
begin
  perform public.suggest_gift((select name from test_third_name), 'one too many');
  raise exception 'FAIL: a sixth idea for the same person was accepted';
exception
  when sqlstate 'P0001' then
    if sqlerrm = 'you have already left 5 ideas for ' || (select name from test_third_name) then
      raise notice 'PASS: the limit of 5 held (%)', sqlerrm;
    else
      raise exception 'FAIL: wrong error: %', sqlerrm;
    end if;
end $$;
reset role;

select count(*) as suggestions_for_the_third_person
from public.gift_suggestions
where recipient_id = (select id from test_third);
-- expect: 5


\echo ''
\echo '== 14. seed.sql is safe to run twice =='
\i db/seed.sql


\echo ''
\echo '== 15. fewer than 3 participants is refused =='
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
\echo '== 16. the privilege surface, stated plainly =='
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
  has_table_privilege('anon','public.gift_suggestions','select')           as anon_sel_suggestions,
  has_table_privilege('authenticated','public.gift_suggestions','insert')  as auth_ins_suggestions,
  has_table_privilege('authenticated','public.gift_suggestions','update')  as auth_upd_suggestions,
  has_table_privilege('authenticated','public.gift_suggestions','delete')  as auth_del_suggestions,
  -- False because the select grant is column-scoped, not table-wide. The
  -- columns themselves are below.
  has_table_privilege('authenticated','public.gift_suggestions','select')  as auth_sel_suggestions_table_wide;
-- expect: f, f, f, f, f

select
  has_column_privilege('authenticated','public.gift_suggestions','suggestion','select')   as sel_suggestion,
  has_column_privilege('authenticated','public.gift_suggestions','link','select')         as sel_link,
  has_column_privilege('authenticated','public.gift_suggestions','recipient_id','select') as sel_recipient_id,
  has_column_privilege('authenticated','public.gift_suggestions','submitter_id','select') as sel_submitter_id,
  has_column_privilege('authenticated','public.gift_suggestions','created_at','select')   as sel_created_at;
-- expect: t, t, t, f, f

select
  has_column_privilege('authenticated','public.gift_suggestions','suggestion','update') as upd_suggestion,
  has_column_privilege('authenticated','public.gift_suggestions','link','update')       as upd_link;
-- expect: f, f

select
  has_column_privilege('authenticated','public.participants','wishlist','update')   as upd_wishlist,
  has_column_privilege('authenticated','public.participants','is_admin','update')   as upd_is_admin,
  has_column_privilege('authenticated','public.participants','name','update')       as upd_name,
  has_column_privilege('authenticated','public.participants','id','update')         as upd_id,
  has_column_privilege('authenticated','public.participants','updated_at','update') as upd_updated_at;
-- expect: t, f, f, f, f

\echo '== RLS is on for all three tables =='
select relname, relrowsecurity as rls_enabled
from pg_class
where oid in (
  'public.participants'::regclass,
  'public.assignments'::regclass,
  'public.gift_suggestions'::regclass
)
order by relname;
-- expect: all three t

\echo '== the policies that exist =='
select tablename, policyname, cmd
from pg_policies
where schemaname = 'public'
order by tablename, policyname;

\echo ''
\echo '== all checks finished =='
