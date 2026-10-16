// Everything the organizer has to edit lives in this file.
//
// The anon key is committed on purpose. It is designed to be published in a web
// page: it identifies the project and nothing more. What a holder of it can
// actually read is decided by the row-level security policies in db/schema.sql,
// not by keeping the key secret.
//
// The service role key is a different thing entirely. It bypasses every policy.
// Never put it in this file, in this repo, or in a chat message.

// ---------------------------------------------------------------------------
// Fill these two in. Supabase dashboard -> Project Settings -> API.
// ---------------------------------------------------------------------------

export const SUPABASE_URL = "https://etuawukjlzwviuyybscw.supabase.co"; // e.g. https://abcdefgh.supabase.co
export const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV0dWF3dWtqbHp3dml1eXlic2N3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIxNDg4NTEsImV4cCI6MjEwNzcyNDg1MX0.w6Qc_Cnh-n9BHMXPS7a0StC6urIz4x12gt9Btx2nuzk";

// ---------------------------------------------------------------------------
// The group. Change these only if the people change.
// ---------------------------------------------------------------------------

// The sign-in dropdown is built from this list, in this order. Each name maps
// to a login address of name.toLowerCase() + "@" + EMAIL_DOMAIN, so these must
// match the auth users the organizer created and the names db/seed.sql derives
// from those addresses.
export const PARTICIPANTS = [
  "Agneta",
  "Christer",
  "Christofer",
  "Tobias",
  "Amelia",
  "Sebastian",
  "Ellie",
];

// Placeholder domain. These are not real inboxes, which is why there is no
// self-service password reset -- see the README.
export const EMAIL_DOMAIN = "secretsanta.local";
