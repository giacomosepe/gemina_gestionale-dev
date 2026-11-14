# Migration from Zite to Supabase

Where we are going: the end-state document in the repository `README.md`. How we get there: this folder and the Linear project "Gemina Migrazione da Zite a Supabase" (P-PM-100).

## Decisions (Giacomo, 13 Nov 2026)

- Architecture A: static React app plus Supabase (Auth, Postgres with access rules, Storage, Edge Functions, queue, scheduled jobs). No server of our own.
- One switch after a full rehearsal on staging, which holds a copy of the real data.
- All data of every domain is imported, including the segnalatori portal.
- Screens built before the switch: contacts, leads, companies, grant matching, pipeline, invoices, summary (riepilogo), cases (pratiche) with services and categories, the segnalatori portal. Signing through the app is deferred (milestone M9); its data is imported.
- The beni and fatture tabs of a case are imported and ported as they are; redesign later.
- Memberships (several organizations per user) come after the migration, if the four rules in the end-state document hold from day one.
- Tables, columns, enum values and function names are in English: see `glossary.md`.
- Gabriele Brioschi and Donato Rondinella have left. They are not invited; their records stay as inactive users.

## Milestones

| | What | Result |
| -- | -- | -- |
| M0 | Foundations | Repo, staging project, login, function base, typed client, data layer, organization helper, audit log, queue, English names |
| M1 | Catalogue (pilot) | Service catalogue on the new layers; the real pace is measured |
| M2 | Companies and contacts | Companies, contacts, grant matching |
| M3 | CRM | Pipeline, deals, activities, leads |
| M4 | Cases and files | Cases, deadlines, messages, files, storage rules |
| M5 | Segnalatori and portal | Referrers, commissions, the portal, admin |
| M6 | Invoicing, integrations, cleanup | Invoices, Qonto, scheduled jobs, upload allowlist, data rights, bridge removal |
| M7 | Rehearsal on staging | Full import, walkthrough of every screen, security pass, restore drill |
| M8 | Cutover and Zite off | One switch, then Zite cancelled and Claude's production access revoked |
| M9 | Deferred | Signing through the app |

Milestone dates are set after the M1 pilot.

## Working rules

- Schema changes follow `CLAUDE.md`: a numbered file first, tested, then applied.
- A renaming of existing tables is not an additive migration. It is applied on staging first (rule 3).
- The Zite export and any reconciliation report hold real data and never enter this repository.
