# Rules for anyone (person or Claude chat) working on this repo

Database: Supabase. Details in `supabase/README.md`.

1. **One builder.** Only the chat Giacomo names changes the Supabase schema. Others read only, until Giacomo says otherwise.
2. **File first.** Every schema change is a new numbered file in `supabase/migrations/`, committed and pushed, then applied. Never change the schema without a file (on 2026-10-19 production drifted from its history this way).
3. **Dev before production.** Claude works only on the dev organization ("Gemina Advisory dev"). Production is a separate, clean project created from these files; no chat is connected to it.
4. **Test and check.** After every change: run the tests in `supabase/tests/` and the Supabase security advisor.
5. **Keys.** Only the publishable key may appear in a browser or a Zite page. Secret keys and bridge secrets live only in Supabase and Zite secret stores, never in this repo.
6. **No real client data in dev.**
