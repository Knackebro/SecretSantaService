-- Secret Santa — link the auth users to participant rows and set the admin.
--
-- Apply this AFTER db/schema.sql and AFTER the 7 auth users exist:
--   Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
--
-- Safe to run twice. If you add a missing person's auth user later, run it
-- again and only the new row is created.

-- One row per auth user with a @secretsanta.local address. The name is derived
-- from the address, so there are no user ids to copy by hand:
-- agneta@secretsanta.local -> 'Agneta'.
insert into public.participants (id, name)
select u.id, initcap(split_part(u.email, '@', 1))
from auth.users u
where u.email like '%@secretsanta.local'
on conflict (id) do nothing;

-- One admin. Sebastian gets the "Run the draw" button; the other six never see
-- that card at all.
update public.participants set is_admin = true  where name = 'Sebastian';
update public.participants set is_admin = false where name <> 'Sebastian';

-- Check the result. Expect 7 and 1. If the first number is lower, an auth user
-- is missing or was created with a different address -- add it in
-- Authentication -> Users and run this file again.
select count(*) as participants,
       count(*) filter (where is_admin) as admins
from public.participants;

-- Deliberately not here: anything that reads public.assignments. The draw is
-- written by run_draw() and read by nobody but its own giver.
