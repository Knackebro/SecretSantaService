// Secret Santa — the whole client.
//
// This file is a convenience, not a security boundary. Every rule about who can
// see what is enforced by row-level security in db/schema.sql. Deleting all of
// the checks below would make the page useless but would not reveal one extra
// row to anybody.
//
// Two rules this file keeps:
//   - It never reads the assignments table. It does not have to: the
//     participants policy already returns exactly the caller's own row and
//     their giftee's row, so "the other row" is the giftee.
//   - It never logs anything data-bearing. The admin is also a participant, so
//     a stray console.log of a draw response is a leak.

import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import {
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  PARTICIPANTS,
  EMAIL_DOMAIN,
} from "./config.js";

const el = (id) => document.getElementById(id);

const show = (node, visible = true) => {
  node.hidden = !visible;
};

// textContent, never innerHTML: wishlists are free text typed by people.
const setText = (node, text) => {
  node.textContent = text;
};

// --- Configured yet? -------------------------------------------------------

const configured =
  SUPABASE_URL.startsWith("https://") && SUPABASE_ANON_KEY.length > 20;

if (!configured) {
  show(el("boot"), false);
  show(el("misconfigured"));
  throw new Error("config.js has not been filled in");
}

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const emailFor = (name) => `${name.toLowerCase()}@${EMAIL_DOMAIN}`;

// The signed-in participant's own row, or null when signed out. Every listener
// below reads this rather than closing over a value from one particular load,
// so the listeners can be attached exactly once.
let me = null;

// --- Sign in ---------------------------------------------------------------

const who = el("who");
for (const name of PARTICIPANTS) {
  const option = document.createElement("option");
  option.value = name;
  setText(option, name);
  who.append(option);
}

el("signin-form").addEventListener("submit", async (event) => {
  event.preventDefault();

  const error = el("signin-error");
  show(error, false);

  const button = el("signin-form").querySelector("button[type=submit]");
  button.disabled = true;

  const { error: signInError } = await supabase.auth.signInWithPassword({
    email: emailFor(who.value),
    password: el("password").value,
  });

  button.disabled = false;

  if (signInError) {
    setText(error, "That password did not work. Ask the organizer to reset it.");
    show(error);
    return;
  }

  el("password").value = "";
  await load();
});

el("signout").addEventListener("click", async () => {
  await supabase.auth.signOut();
  window.location.reload();
});

// --- Load everything the signed-in participant is allowed to see -----------

async function load() {
  show(el("boot"));
  show(el("view-signin"), false);
  show(el("view-app"), false);

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    me = null;
    show(el("boot"), false);
    show(el("view-signin"));
    return;
  }

  // Has the draw happened? A plain boolean from a function that reads the
  // assignments table on the server and returns nothing about its contents.
  const { data: drawDone, error: drawDoneError } = await supabase.rpc("draw_done");

  // One query. The policy decides what comes back: the caller's own row before
  // the draw, their own row plus their giftee's row after it.
  const { data: rows, error: rowsError } = await supabase
    .from("participants")
    .select("id, name, wishlist, is_admin");

  show(el("boot"), false);
  show(el("view-app"));

  if (rowsError || drawDoneError) {
    setText(
      el("giftee"),
      "Could not reach the database. If it has been quiet for a week the " +
        "organizer may need to restore the Supabase project.",
    );
    return;
  }

  me = rows.find((row) => row.id === user.id) ?? null;
  const others = rows.filter((row) => row.id !== user.id);

  if (!me) {
    setText(
      el("giftee"),
      "Your login is not linked to a participant yet. Ask the organizer to run db/seed.sql.",
    );
    return;
  }

  setText(el("greeting"), `Signed in as ${me.name}.`);
  renderGiftee(others, drawDone);
  renderMyWishlist(me);
  renderAdmin(me, drawDone);
}

function renderGiftee(others, drawDone) {
  const giftee = el("giftee");
  const wrap = el("giftee-wishlist-wrap");
  const heading = el("giftee-wishlist-heading");
  const body = el("giftee-wishlist");

  show(wrap, false);

  if (others.length === 0) {
    setText(
      giftee,
      drawDone
        ? "You do not have a giftee. Tell the organizer — this should not happen."
        : "The draw has not happened yet.",
    );
    return;
  }

  if (others.length > 1) {
    // The policy should return at most one other row. More than that means the
    // access rules are not doing what this page assumes, and guessing which
    // name to print would be the wrong way to find out.
    setText(
      giftee,
      "Something is wrong with this site's access rules. Tell the organizer and do not trust what you see.",
    );
    return;
  }

  const [them] = others;
  setText(giftee, `You are giving a present to ${them.name}.`);
  show(wrap);

  if (them.wishlist.trim() === "") {
    setText(heading, `${them.name} has not added a wishlist yet.`);
    setText(body, "");
    show(body, false);
    return;
  }

  setText(heading, `${them.name}'s wishlist`);
  setText(body, them.wishlist);
  show(body);
}

// --- My wishlist -----------------------------------------------------------

function renderMyWishlist(row) {
  el("wishlist").value = row.wishlist;
  setText(el("wishlist-status"), "");
  el("wishlist-status").classList.remove("bad");
}

// Clear a stale "Saved." as soon as the text stops matching what was saved.
el("wishlist").addEventListener("input", () => {
  setText(el("wishlist-status"), "");
  el("wishlist-status").classList.remove("bad");
});

el("wishlist-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!me) return;

  const status = el("wishlist-status");
  const button = el("wishlist-save");

  button.disabled = true;
  setText(status, "Saving…");

  const { error } = await supabase
    .from("participants")
    .update({ wishlist: el("wishlist").value })
    .eq("id", me.id);

  button.disabled = false;
  setText(status, error ? "Could not save. Try again." : "Saved.");
  status.classList.toggle("bad", Boolean(error));
});

// --- My password -----------------------------------------------------------

// The two inputs are the only place a typed password ever lives: it is never
// logged, never put in a variable that outlives the submit, and both fields are
// cleared the moment Supabase accepts it.
//
// No `me` guard here, unlike the wishlist. Changing a password needs the auth
// session and nothing else, so this still works for somebody whose participant
// row is missing or whose database read failed.

// An expired or revoked session is the one failure where Supabase's own wording
// is about tokens rather than about anything a participant can do. GoTrue
// answers 401 for a missing token and 403 for a bad one; the codes are listed
// as well because they are the documented names for those two cases.
const sessionIsDead = (error) =>
  error.status === 401 ||
  error.status === 403 ||
  ["bad_jwt", "no_authorization", "session_not_found"].includes(error.code);

// Clear a stale "Password updated." or complaint as soon as either field is
// edited again, the same way the wishlist clears its "Saved."
for (const id of ["new-password", "new-password-repeat"]) {
  el(id).addEventListener("input", () => {
    setText(el("password-status"), "");
    show(el("password-error"), false);
  });
}

el("password-form").addEventListener("submit", async (event) => {
  event.preventDefault();

  const status = el("password-status");
  const error = el("password-error");
  const button = el("password-save");
  const first = el("new-password");
  const second = el("new-password-repeat");

  setText(status, "");
  show(error, false);

  const complain = (message) => {
    setText(error, message);
    show(error);
  };

  if (first.value !== second.value) {
    complain("The two passwords do not match.");
    return;
  }

  if (first.value.length < 8) {
    complain("Please use at least 8 characters.");
    return;
  }

  button.disabled = true;
  setText(status, "Saving…");

  const { error: updateError } = await supabase.auth.updateUser({
    password: first.value,
  });

  setText(status, "");
  button.disabled = false;

  if (updateError) {
    if (sessionIsDead(updateError)) {
      first.value = "";
      second.value = "";
      await supabase.auth.signOut();
      // load() finds no user and puts the sign-in view back up. Setting the
      // message after it, because load() is what hides this card.
      await load();
      setText(el("signin-error"), "Your session has expired — please sign in again.");
      show(el("signin-error"));
      return;
    }

    // Supabase's own message is the clearest thing to show: "New password
    // should be different from the old password.", "Password should be at
    // least 6 characters.", and so on are already plain English.
    complain(updateError.message);
    return;
  }

  first.value = "";
  second.value = "";
  setText(status, "Password updated. Use it next time you sign in.");
});

// --- Admin -----------------------------------------------------------------

function renderAdmin(row, drawDone) {
  if (!row.is_admin) return;

  show(el("view-admin"));

  if (drawDone) {
    setText(el("admin-state"), "The draw is done.");
    show(el("redraw-button"));
    show(el("draw-button"), false);
    return;
  }

  setText(el("admin-state"), "The draw has not been run yet.");
  show(el("draw-button"));
  show(el("redraw-button"), false);
}

el("draw-button").addEventListener("click", () => {
  if (!window.confirm("Run the draw? Everyone gets their giftee straight away.")) return;
  runDraw(false);
});

el("redraw-button").addEventListener("click", () => {
  if (!window.confirm("Throw away the current draw and run a new one?")) return;
  if (!window.confirm("Really redraw? Anyone who has already looked will see a different name.")) return;
  runDraw(true);
});

async function runDraw(redraw) {
  const result = el("draw-result");
  const error = el("draw-error");
  const drawButton = el("draw-button");
  const redrawButton = el("redraw-button");

  show(error, false);
  setText(result, "Drawing…");
  drawButton.disabled = true;
  redrawButton.disabled = true;

  // run_draw returns one integer. That is the entire result: the pairs are
  // written inside Postgres and never leave it. Nothing below fetches or
  // renders anything from the assignments table — the admin sees their own
  // giftee the same way everyone else does, by reloading the page.
  const { data: written, error: drawError } = await supabase.rpc("run_draw", {
    p_redraw: redraw,
  });

  drawButton.disabled = false;
  redrawButton.disabled = false;

  if (drawError) {
    setText(result, "");
    setText(error, `The draw did not run: ${drawError.message}`);
    show(error);
    return;
  }

  setText(
    result,
    `${written} assignments written. Reload the page to see who you are giving to.`,
  );
  setText(el("admin-state"), "The draw is done.");
  show(drawButton, false);
  show(redrawButton);
}

// --- Go --------------------------------------------------------------------

await load();
