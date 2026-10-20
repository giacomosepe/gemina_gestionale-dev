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
- **Production (new, clean project):** apply every file in `migrations/` in order, baseline first, nothing skipped.
- **Dev (gsnmtfugfhhrutmlvhzt):** this is the project the baseline was read from, so it already had the baseline's
  structure; its history also lists 5 older migrations from before the baseline. Nothing to do there.
- (Until 2026-10-20 this section said to mark the baseline as applied on production: that was for the old plan in
  which gsnmtfugfhhrutmlvhzt was production. Ignore it.)

## Settings that are not SQL (set once per project)
- Auth: sign-ups disabled; site URL and redirect URLs; leaked-password protection or password sign-in off.
- Edge Function `portal-bridge` deployed (verify_jwt off: it checks its own secrets), with secrets `BRIDGE_SECRET_STAFF` and `BRIDGE_SECRET_PORTAL` (different values).
- Staff accounts are not created by hand: the bridge makes them from the Gestionale's Ruoli (see migration 20261020183659).
- Bridge action `notify` (both secrets): Zite's bell events for one current staff member. With the portal secret only the
  Portal's own events (messaggio-segnalatore, nuova-segnalazione, primo-accesso) and segnalatore links, and no actor.
  Kind `event` labels are Zite's bell text: a future unread-email job must skip them (Zite emails those itself).
- Bridge action `sync_partner` (staff secret): segnalatori created, edited, archived or deleted in the Gestionale update
  `public.partners` (deleted = archived). Edge Function settings: **production** `PARTNER_EMAILS_REAL=true`; **dev**
  `DEV_TEST_PARTNER_EMAILS` = Giacomo's test addresses (comma separated). Without them real referrer emails are replaced
  by placeholders (dev keeps no real referrer data). Archiving or an email change drops portal memberships at once;
  a deleted segnalatore is archived with its email released. Action `archive_missing_partners` (repair, run by the
  Gestionale's admin endpoint `sincronizzaSegnalatoriSupabase`) archives referrers that no longer exist in Zite.
- Later: token hook, MFA, Resend key.
