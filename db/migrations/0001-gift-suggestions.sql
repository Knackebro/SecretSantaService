-- Secret Santa — gift suggestions. Migration 0001.
--
-- Apply this AFTER db/schema.sql:
--   Supabase dashboard -> SQL Editor -> New query -> paste this whole file -> Run.
--
-- A fresh project applies db/schema.sql and then every file in db/migrations in
-- number order. A project that is already running the site applies only this
-- file. Nothing here touches the participants or assignments tables, so a
-- completed draw survives it.
--
-- What this adds: anyone in the group can leave a gift idea for somebody else.
-- Only that person's Secret Santa sees it, and even they cannot see who wrote
-- it. Those two rules are enforced here, in the database. The JavaScript in the
-- site is a convenience. A participant who calls the REST API from the browser
-- console is held to exactly the rules below.

-- ---------------------------------------------------------------------------
-- The table
-- ---------------------------------------------------------------------------

create table public.gift_suggestions (
  id           uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.participants(id) on delete cascade,
  submitter_id uuid not null references public.participants(id) on delete cascade,
  suggestion   text not null,
  link         text,
  created_at   timestamptz not null default now(),

  -- Suggesting a gift for yourself is not a thing. Your own wishlist is.
  constraint gift_suggestions_not_self check (recipient_id <> submitter_id),

  -- The length limits are here as well as in suggest_gift() below. The function
  -- exists to give a person a readable message; these constraints are what make
  -- the limit true no matter how a row is written.
  constraint gift_suggestions_text_length check (length(btrim(suggestion)) between 1 and 500),
  constraint gift_suggestions_link_shape check (
    link is null or (length(link) <= 500 and link ~ '^https?://')
  )
);

-- Every read of this table filters on recipient_id.
create index gift_suggestions_recipient_idx on public.gift_suggestions (recipient_id);

-- Why submitter_id is stored at all, given that the point is anonymity:
--   - suggest_gift() needs it to cap how many ideas one person can leave for
--     one other person.
--   - the organizer needs it if somebody writes something nasty.
-- No participant can read it. The grant below leaves that column out, so
-- "select submitter_id from gift_suggestions" fails with "permission denied for
-- table gift_suggestions" even for the Secret Santa who can read the row. Note
-- that "select *" fails for the same reason, because it asks for that column
-- too. Anything reading this table has to name the columns it wants.

-- ---------------------------------------------------------------------------
-- Column privileges
-- ---------------------------------------------------------------------------
-- Supabase's default privileges grant ALL on new public tables to anon and
-- authenticated, so this revoke is not optional.

revoke all on table public.gift_suggestions from anon, authenticated;

-- A participant may read four columns. Which rows is the policy's call.
-- Deliberately not granted:
--   submitter_id  -- that is the anonymity
--   created_at    -- the arrival order is a hint about who wrote a note, and
--                    nothing in the site needs a timestamp. Ordering by a
--                    column also needs select on it, so leaving it out means
--                    the site orders by id, which carries no time.
grant select (id, recipient_id, suggestion, link)
  on table public.gift_suggestions to authenticated;

-- Nobody signed in may insert, update or delete a row directly. The only
-- writer is suggest_gift() below, which runs as the definer and so is not held
-- to these grants.

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
-- With RLS on and no permissive policy for a command, that command is denied.
-- There is deliberately no insert, update or delete policy here.

alter table public.gift_suggestions enable row level security;

-- You read the ideas left for the one person you are giving to. Not the ideas
-- left for you, and not anybody else's. private.my_giftee_id() is the same
-- definer function the participants policy uses, so "who is my giftee" is
-- answered in one place. Before the draw it returns null, no row matches, and
-- the site shows nothing.
create policy "gift suggestions for my giftee" on public.gift_suggestions for select
  using (recipient_id = private.my_giftee_id());

-- ---------------------------------------------------------------------------
-- Leaving a suggestion
-- ---------------------------------------------------------------------------
-- The caller names the person, because a participant cannot read anybody's row
-- except their own and their giftee's, so the browser has no id to send. This
-- function turns the name into an id as the definer.
--
-- It takes the name from the dropdown in config.js. An unknown name is an
-- error rather than a silent no-op, so a typo in that list is visible.

create or replace function public.suggest_gift(
  p_for_name   text,
  p_suggestion text,
  p_link       text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recipient  uuid;
  v_suggestion text := btrim(coalesce(p_suggestion, ''));
  v_link       text := nullif(btrim(coalesce(p_link, '')), '');
  v_mine       integer;
begin
  if not exists (
    select 1 from public.participants where id = auth.uid()
  ) then
    raise exception 'only a participant can suggest a gift';
  end if;

  if v_suggestion = '' then
    raise exception 'write something before you save it';
  end if;

  if length(v_suggestion) > 500 then
    raise exception 'a suggestion has to be 500 characters or fewer';
  end if;

  if v_link is not null and v_link !~ '^https?://' then
    raise exception 'a link has to start with http:// or https://';
  end if;

  if v_link is not null and length(v_link) > 500 then
    raise exception 'a link has to be 500 characters or fewer';
  end if;

  select id into v_recipient
  from public.participants
  where name = p_for_name;

  if v_recipient is null then
    raise exception 'there is nobody called % in the group', p_for_name;
  end if;

  -- Deliberately not checked: whether the caller is this person's Secret Santa.
  -- Refusing that case would tell the caller who they are giving to, which is
  -- the one thing this site exists to keep quiet. Somebody leaving a note for
  -- their own giftee is harmless — they are writing to themselves.
  if v_recipient = auth.uid() then
    raise exception 'you cannot suggest a gift for yourself — that is what your wishlist is for';
  end if;

  select count(*) into v_mine
  from public.gift_suggestions
  where recipient_id = v_recipient
    and submitter_id = auth.uid();

  if v_mine >= 5 then
    raise exception 'you have already left 5 ideas for %', p_for_name;
  end if;

  insert into public.gift_suggestions (recipient_id, submitter_id, suggestion, link)
  values (v_recipient, auth.uid(), v_suggestion, v_link);
end;
$$;

revoke execute on function public.suggest_gift(text, text, text) from public;
grant  execute on function public.suggest_gift(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- What this does not hide
-- ---------------------------------------------------------------------------
-- Two honest limits, in the same spirit as the draw:
--
--   - Whoever is signed in to the Supabase dashboard can open this table and
--     read submitter_id. No design on a hosted database avoids that.
--   - A Secret Santa who recognises somebody's turn of phrase can guess who
--     wrote a note. The database can hide a name; it cannot hide a writing
--     style.
