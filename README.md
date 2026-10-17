# Secret Santa

A small Secret Santa site for seven people. Everyone signs in, sees the one
person they are giving a present to and that person's wishlist, edits their own
wishlist and can change their own password. Anyone can also leave an anonymous
gift idea for somebody else, which only that person's Secret Santa sees. One
person is the admin and gets a **Run the draw** button.

- Site: <https://knackebro.github.io/SecretSantaService/>
- Hosting: GitHub Pages, served straight from `main` / `(root)`
- Data and sign-in: Supabase (free tier)

There is no build step. Plain HTML, CSS and JavaScript, served exactly as
committed. `@supabase/supabase-js` is loaded from a CDN as an ES module.

## How the secret stays secret

The person who presses the draw button is also a participant, so the draw is
built so that pressing it tells them **one number and nothing else**.

- The draw runs inside Postgres (`run_draw()` in `db/schema.sql`). It writes the
  pairs and returns a count. The pairs never travel to the browser.
- Row-level security decides what anyone can read. A participant can read their
  own row and their giftee's row — nobody else's. Opening the browser console
  and calling the API directly does not help, because the rules are in the
  database, not in the JavaScript.
- The browser has no insert, update or delete rights on the draw table at all.

One honest limit: whoever is signed in to the **Supabase dashboard** can open
the table and read all seven rows. No design on a hosted database avoids that.
The button hides the draw from you by default; it cannot stop you from
deliberately looking. That last part is discipline, not engineering.

## Files

```
index.html     sign-in, participant views, suggest-a-gift card, admin card
app.js         auth, load assignment, save wishlist, suggest a gift, change password, call run_draw
styles.css
config.js      Supabase project URL + anon key, and the list of names
db/schema.sql  tables, RLS policies, column grants, run_draw, draw_done
db/seed.sql    links the auth users to participant rows, sets the admin

db/migrations/0001-gift-suggestions.sql   the gift_suggestions table and suggest_gift

db/test/harness.sql   checks the schema against a throwaway Postgres
```

`db/schema.sql` is the first version of the database. Everything changed since
then is a numbered file in `db/migrations`, because the real project already has
the schema applied and pasting that file again would fail on the first `create
table`. A fresh project runs `db/schema.sql` and then every migration in number
order. The real project runs only the migrations it has not had yet.

`db/test/harness.sql` is for whoever changes the database, not for the
organizer. It applies `db/schema.sql`, the migrations and `db/seed.sql` to a
scratch database and checks the draw rules, the gift-suggestion rules and the
access rules as a signed-in participant — it prints counts and true/false only,
never a pair and never a suggestion's author. **It deletes participants and the
draw, so it must never be pointed at the real project.** It refuses to start if
it finds participants already there, and the run instructions are in the file's
header comment.

The anon key in `config.js` is committed on purpose. It is designed to be
published in a web page — it names the project and nothing more. The **service
role key** is a different thing: it bypasses every rule above. Never put it in
this repo.

## Setup — the organizer's five steps

### 1. Make this repo public

GitHub Pages on a free plan cannot serve a private repo.

Settings → General → Danger Zone → Change visibility → Public.

Safe to do: the only things in here are the site and the anon key.

### 2. Create the Supabase project and apply the schema

Create a free project at <https://supabase.com>. Then SQL Editor → New query →
paste the whole of `db/schema.sql` → Run.

Then do the same for each file in `db/migrations`, in number order. Right now
that is one file, `0001-gift-suggestions.sql`. **If the project already exists,
this is the only step it needs** — the migrations are the changes made since
the first version of the schema, and none of them touch the draw.

Supabase's REST API notices a new table a few seconds after the SQL runs. If
the site complains that it could not load the gift suggestions, wait a moment
and reload before looking for a real fault.

### 3. Fill in `config.js`

Project Settings → API gives you the **Project URL** and the **anon public**
key. Put them in `config.js`, replacing `PASTE_PROJECT_URL_HERE` and
`PASTE_ANON_KEY_HERE`, and commit. Until this is done the site shows "This site
has not been pointed at its database yet."

While you are in the dashboard, set Project Settings → API → **Site URL** to
`https://knackebro.github.io/SecretSantaService/`. Nothing in this site needs
it today, but it is the right value if a redirect-based sign-in is ever turned
on.

### 4. Create the seven logins, then seed

Authentication → Users → **Add user**, seven times, with **Auto Confirm User**
checked so no email is sent:

| Name | Email |
| --- | --- |
| Agneta | `agneta@secretsanta.local` |
| Christer | `christer@secretsanta.local` |
| Christofer | `christofer@secretsanta.local` |
| Tobias | `tobias@secretsanta.local` |
| Amelia | `amelia@secretsanta.local` |
| Sebastian | `sebastian@secretsanta.local` |
| Ellie | `ellie@secretsanta.local` |

Pick a password for each and hand them out directly. The addresses are
placeholders and not real inboxes — see **Passwords** below.

Then SQL Editor → paste `db/seed.sql` → Run. It derives each name from the
address, so there are no user ids to copy by hand. It prints a count at the end:
expect **7 participants, 1 admin**. If the count is lower, an auth user is
missing or was created with a different address — fix it and run the file again.

### 5. Turn on Pages

Settings → Pages → Build and deployment → Source: **Deploy from a branch** →
Branch: **`main`** / **`(root)`** → Save. Give it a minute, then open the site
URL.

## Running the draw

Sign in as **Sebastian** and press **Run the draw**, then confirm. The page
shows `7 assignments written.` and nothing else — no pairs, no participant list,
no "who has written a wishlist yet" view. Reload to see your own giftee the same
way everybody else does.

Pressing it a second time refuses with *"a draw already exists"*. To genuinely
start over, use **Redraw**, which is behind two confirmations and throws the old
draw away. Anyone who has already looked will see a different name, so only do
this before you tell people to look.

A draw is all-or-nothing: it either writes a complete valid ring or writes
nothing. Before the draw, everyone sees "The draw has not happened yet."

## Gift suggestions

Anyone can leave a gift idea for anyone else. **Suggest a gift for someone** →
pick a name → write the idea → add a link if you have one → **Save
anonymously**.

Where it ends up: on the page of that person's Secret Santa, under their
wishlist, as "two anonymous ideas for Amelia". Nobody else sees it.

Three things the site does not do, each on purpose.

- **It does not show you the ideas you wrote.** The only way to show you your
  own notes would be to record that they are yours in a way the site can read
  back, and then that is one access rule away from the Secret Santa reading it
  too. Read it over before you save it; there is no edit button.
- **It does not show you that person's wishlist while you type.** A participant
  can only read their own row and their giftee's row, and that is the rule the
  whole site rests on. So you may well suggest something they already asked
  for. That is the cheaper of the two problems.
- **It does not tell the Secret Santa who wrote anything, or when.** Not the
  name, not the order the ideas arrived in.

You can leave five ideas for any one person. After that the site says so. The
limit exists so one person cannot fill somebody's page.

Suggestions work before the draw as well. They sit there and appear on the
right person's page as soon as the draw runs.

### How that stays anonymous

Same approach as the draw: the rules are in the database, not in the
JavaScript. See `db/migrations/0001-gift-suggestions.sql`.

- The browser cannot write to the table at all. Suggestions go in through
  `suggest_gift()`, which runs inside Postgres and records who called it.
- Row-level security answers the read: you get the rows for the one person you
  are giving to, and no others. The person a note is about cannot read it, and
  neither can the person who wrote it.
- The `submitter_id` column is not granted to anyone signed in. Even the Secret
  Santa who can read the note gets "permission denied" for that column. The
  same is true of `created_at`, so the arrival order is not a hint either.

The honest limits, like the draw's:

- Whoever is signed in to the **Supabase dashboard** can open the table and see
  who wrote what. That is also how you deal with somebody writing something
  nasty.
- A Secret Santa who recognises a turn of phrase can guess who wrote a note.
  The database can hide a name. It cannot hide a writing style.

## Passwords

Two different situations, two different answers.

**Someone knows their password and wants a different one.** They do it
themselves: sign in → **Change my password** on their own page → new password
twice → **Save**. It takes effect the next time they sign in, they stay signed
in meanwhile, and nothing is emailed. Minimum eight characters, and Supabase
refuses a password identical to the current one.

This needs Authentication → Providers → Email → **Secure password change** to
stay **off** (it is off by default). Turning it on makes Supabase demand a
one-time code by email for any session older than 24 hours, and these addresses
receive no email — so the button would simply stop working for most people.

**Someone has forgotten their password.** **There is no self-service reset.**
The addresses are placeholders, so a reset email has nowhere to go and the
"forgot password" and magic-link flows cannot work at all. They cannot sign in,
so they never reach the form above either.

Reset it by hand instead: Supabase dashboard → Authentication → Users → find the
person → the **⋯** menu on their row → **Reset password** (or **Send magic
link**, which will not help here) → set a new password and tell them what it is.

## If the site stops working

A free Supabase project **pauses after 7 days with no database activity**. While
paused, sign-in and everything else simply fail, and the site says it could not
reach the database. Nothing is deleted.

Open the Supabase dashboard and click **Restore project**. A paused project
stays restorable for a year, and the owner gets a warning email first. For a
tool used in bursts around Christmas, expect to click Restore before each use.

## Changing the group

Edit `PARTICIPANTS` in `config.js`, add or remove the matching auth user in the
dashboard, and run `db/seed.sql` again. If a draw already exists, redraw.

Removing somebody also deletes the gift suggestions they wrote and the ones
written for them. That is the `on delete cascade` on both columns: a note whose
author no longer exists has nobody accountable for it, and a note for somebody
who left has no Secret Santa to read it.
