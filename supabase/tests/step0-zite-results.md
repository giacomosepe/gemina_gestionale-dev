# Step 0: can Zite pages talk to Supabase directly? (2026-10-19)

Test app in Zite: "Supabase test (throwaway)" (id fgiauzp4tn, internal), against the DEV project.
No Supabase library used: only the browser's fetch and WebSocket.

| Check | Chrome, preview | Chrome, published (internal) | Arc |
|---|---|---|---|
| 1. HTTP request to Supabase | pass | pass | pass |
| 2. Live connection (WebSocket) | pass | pass | first try failed (likely Arc privacy/tracker blocking), later passed |
| 3. Zite login -> Supabase login via portal-bridge (1 Zite run) | | pass | |
| 4. Read data as that user (RLS applies) | | pass | |
| 5. Realtime subscription with that login | | pass | |

Conclusions
- Plan A holds: the browser of a Zite page can read/write Supabase and receive live updates directly. Zite's page security policy does not block it.
- Some browsers or extensions can block the live connection: the app must fall back to plain requests (on focus, on open, every ~60 s while a conversation is open). Those still cost 0 Zite runs.
- The session costs 1 Zite run per token (about 1 hour, no refresh token by design).
- Installing `@supabase/supabase-js` with `yarn install` in a Zite build sandbox changed shared packages and broke the type check of the Gestionale (`src/lib/numeri.ts`). Not committed. Before adding the library for real: install it in a way that does not move other apps' dependencies, and type-check both apps. Plain fetch/WebSocket remains an option.
- Bridge secrets: set by Giacomo (Supabase Edge Function secrets BRIDGE_SECRET_STAFF / BRIDGE_SECRET_PORTAL; Zite secret ZITE_BRIDGE_SECRET_STAFF on the test app only). A first mismatch was diagnosed by comparing SHA256 fingerprints (Supabase dashboard vs Zite), never the values.

Still to test
- The external portal on its own domain (partners.geminaadvisory.com) with the portal secret and a referrer login.
- Delete the throwaway app when no longer needed.
