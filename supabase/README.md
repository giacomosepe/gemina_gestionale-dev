# Supabase: Gemina messaging, comments and portal

Plan: `piano-database-supabase.md` (v0.3) and the review `claude/2026-10-19-verifica-supabase-produzione.md` in the project folder.

## Projects
| | Project | Ref | Region | Who touches it |
|---|---|---|---|---|
| Dev | Gestionale Gemina Advisory EU (org "Gemina Advisory dev", free plan) | gsnmtfugfhhrutmlvhzt | eu-central-1 | Claude; test data only (real aziende names, referrer emails replaced) |
| Production | not created yet (Pro, Frankfurt) | — | eu-central-1 | Giacomo creates it from these files; no chat connected |

(Until 2026-10-19 this table listed gsnmtfugfhhrutmlvhzt as production and an older tzbssapqpdtjljtphsiy as dev. gsnmtfugfhhrutmlvhzt became dev that evening; production will be a new, clean project.)

## Words
- **staff** = Gemina's team, mirrors the Zite table Ruoli (Amministratore → `admin`, Manager → `manager`). `former_staff` = left the team: no access, profile kept for history.
- **partner** = a segnalatore (referrer). In the Gestionale's screens Gemina's own people are called *Manager*.

## Rules
1. Every change is a file in `migrations/`, applied to dev first, tested, then to production. Never edit production by hand.
2. Only the publishable key may appear in a browser or a Zite page. Secret keys and bridge secrets live only in Supabase / Zite secret stores.
3. After every change: run the tests in `tests/` and the security advisor.

## Baseline (20261019180000_baseline_from_production.sql)
It is the structure of production on 2026-10-19, read from its catalog (production had changes applied outside recorded migrations).
- **Dev / new projects:** apply it normally.
- **Production:** already has all of it. Do NOT run it there. Mark it as applied instead, e.g. with the CLI:
  `supabase migration repair --status applied 20261019180000`
  (the 5 older production migrations can be marked `reverted` the same way, since the baseline replaces them).

## Settings that are not SQL (set once per project)
- Auth: sign-ups disabled; site URL and redirect URLs; leaked-password protection or password sign-in off.
- Edge Function `portal-bridge` deployed (verify_jwt off: it checks its own secrets), with secrets `BRIDGE_SECRET_STAFF` and `BRIDGE_SECRET_PORTAL` (different values).
- Staff accounts are not created by hand: the bridge makes them from the Gestionale's Ruoli (see migration 20261020183659).
- Later: token hook, MFA, Resend key.
