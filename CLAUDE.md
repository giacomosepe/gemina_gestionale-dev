# Rules for anyone (person or Claude chat) working on this repo

Database: Supabase. Details in `supabase/README.md`.

1. **One builder.** Only the chat Giacomo names changes the Supabase schema. Others read only, until Giacomo says otherwise.
2. **File first.** Every schema change is a new numbered file in `supabase/migrations/`, committed and pushed, then applied. Never change the schema without a file (on 2026-10-19 production drifted from its history this way).
3. **Dev before production.** Every change is built and tested on dev ("Gemina Advisory dev") first. Production is a separate, clean project created from these files. Decided by Giacomo on 2026-10-21: while the only users are the test group (people who know the system is still being built), the chat Giacomo names may also be connected to production, to apply the tested files, deploy the functions, run the tests and the advisor, and diagnose. Never for one-off changes outside rule 2. **Before the first segnalatore or client outside the test group uses the apps, Giacomo revokes Claude's access to production** (Supabase connector); from then on no chat is connected to it, and changes reach production through the repo files.
4. **Test and check.** After every change: run the tests in `supabase/tests/` and the Supabase security advisor.
5. **Keys.** Only the publishable key may appear in a browser or a Zite page. Secret keys and bridge secrets live only in Supabase and Zite secret stores, never in this repo.
6. **No real client data in dev.**
