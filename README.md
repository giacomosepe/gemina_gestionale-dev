Gestionale Gemina: stato di arrivo

Nov 13, 2026 · @giacomo Sepe

Purpose

We are building a practice-management app for consultancies that runs entirely on Supabase, with no Zite and no server to maintain. It starts as Gemina's own tool and stays ready to be offered to other firms later.

- Now: every Gestionale feature and the segnalatori portal move off Zite, with the same behaviour and no data lost. The Zite subscription (€80 a month) ends.
- Next: a client portal, built as a separate product that can also be used on its own.
- Later: the same app for other firms (multi-tenant), with memberships, self-signup and billing added only when a second customer is real.

The priority order for every choice: maintenance time first, then security, then cost, then speed of delivery. The cleanups listed here are part of the work, not extras: the arrival state is a well-structured app, not a copy of today's.

What a proper app must have

A proper app is one a stranger could sign into, trust with client data, and that we can change without fear. In practice that means these capabilities, all present at arrival:

Area

At arrival

Sign-in

Supabase Auth, invite-only, email magic link or Google; staff, segnalatori and (later) clients with separate access

Permissions

The permission matrix in the database, checked by every write and every read rule; managed from an admin screen, not by SQL

Data isolation

Every row belongs to an organization; access rules enforce it; a two-organization test proves it

Core features

Companies and contacts, CRM pipeline, pratiche with service catalogue, signatures, segnalatori and commissions, invoicing with Qonto, cash flow and VAT, supplier invoices and beni, messages, files, reminders

Integrations

Qonto, Google Drive, Resend, Anthropic, each behind one Edge Function with its own secret

Background work

A queue with retries for imports, notifications and syncs; scheduled jobs for the nightly ones

Audit

One log of who changed what and when, on every business table

Files

Private storage, per-organization folders, signed links, allowlisted file types

Errors

Every failure shows the user a clear Italian message and leaves a log line we can find

Settings

Organization settings and catalogue editable in the app (no developer needed)

Data rights

Export of all data; deletion of a contact or company on request (GDPR)

Architecture at arrival

The browser runs a static React app and talks only to Supabase; only Edge Functions reach Qonto, Drive, Resend and Anthropic. There is no server of our own.

[embed: node/f5db9e4f-9ad2]

The app signs in through Auth, reads simple lists straight from Postgres under the access rules, and sends every write and every rule to the Edge Function of its domain, which also runs the queued jobs.

Frontend structure

Every screen is built from five separate layers, and each kind of code lives in exactly one of them. A component never calls the database; a data function never draws anything; styling never lives in logic.

Today the app already has good habits to keep: one component per file, one page frame (Pagina), all non-action buttons in shared/, the record layout in one file (shared/scheda/layout.ts), no component over 400 lines. The main gap: 155 of the 400 components call the back end directly, there is no shared data-fetching layer (a home-made cache in cacheDati.ts), and business rules sit partly in components.

Layer

Folder

Holds

Never holds

Pages

src/features/<domain>/pages/

One file per route: reads the URL, picks the layout, composes components, calls hooks

Database calls, styling details, business rules

Layouts

src/app/layouts/

App shell (sidebar, header), the page frame, the record layout (tabs, columns)

Data, feature-specific content

Components

src/features/<domain>/components/ and src/ui/

What is drawn: props in, events out. src/ui/ = the design kit (buttons, fields, chips, dialogs, tables) shared by all features

Data fetching, business rules

Hooks (state and data)

src/features/<domain>/hooks/

usePratica(id), useSalvaPratica(): fetching, caching, loading and error states, optimistic updates, via one query library (TanStack Query)

Drawing, styling

API client

src/features/<domain>/api.ts

Typed calls to Supabase (direct reads) and to the domain's Edge Function (writes and rules)

Anything visual; any rule the server must enforce

Pure logic

src/features/<domain>/logic/ and shared/logic/

Formatting, calculations, validation shared with the server (Zod schemas), Italian amounts and dates

Network, React

Styling

tailwind.config.ts + src/ui/tokens.ts

Colours, spacing, type as tokens; Tailwind classes only inside components and src/ui/

Hex colours or inline style= in features

Rules that keep it that way:

- Routing: real URLs (/pratiche/PR-001), not hash routes, so links can be shared and bookmarked.
- Types: one generated set of database types (supabase gen types) and one Zod schema per form, used by the form, the API client and the Edge Function alike.
- Errors and loading: one pattern for every screen (skeleton, empty state, error with retry), provided by the hooks, not rewritten per page.
- Feature folders mirror the back end: features/pratiche on the screen side, functions/pratiche on the server side, same names.
- Tests: pure logic tested without a browser; one browser test per main flow (create a pratica, issue an invoice, invite a segnalatore).

Back end structure

Business logic lives in TypeScript Edge Functions, one per domain; the database is the safety net. The same layering as the screens applies: a handler never writes SQL by hand, a rule never lives only in the browser.

Layer

Where

Holds

Router

supabase/functions/<domain>/index.ts

One Edge Function per domain (aziende, crm, pratiche, firme, segnalatori, fatture, admin, portale); routes an action to its handler, checks sign-in, reads the organization from the one helper

Handlers

supabase/functions/<domain>/handlers/

One file per action (salvaPratica.ts): validate input (shared Zod schema), check the permission, call the domain logic, return a typed result

Domain logic

supabase/functions/_shared/<domain>/

Today's lib/ code (17.7k lines), moved with its tests: rules, calculations, workflows. No HTTP, no SQL strings

Data layer

supabase/functions/_shared/db/

Typed queries (Kysely) run inside one transaction as the signed-in user, so access rules still apply; replaces zitejs/db and zite.sql

Integrations

supabase/functions/_shared/integrations/

Qonto, Drive, Resend, Anthropic clients; each reads its own secret; nothing else calls those services

Jobs

supabase/functions/jobs/ + pgmq + pg_cron

Queue consumers with retries (imports, notifications, syncs) and the nightly schedules

Database

supabase/migrations/

Tables, constraints, access rules, the permission and organization helpers, small atomic functions, the audit trigger. No workflows in SQL

Rules:

- Reads: simple lists and details may go straight from the app to the database through the access rules; anything that combines rules goes through a handler.
- Writes: always through a handler, except trivial single-field edits the access rules fully cover.
- Privileged actions (service key, webhooks, other organizations' data) only in Edge Functions, never reachable from the browser.
- Existing SQL functions (invoicing, commissions) move to TypeScript only when next changed.

Data model and multi-tenancy

One Postgres database, every business row tagged with its organization, and one helper that says which organization the user is in. Memberships come after the migration; these rules make adding them a change in one place.

- Organization on every row: every business table has organization_id not null, checked by its access rules. Shared reference data (ATECO codes, provinces, bandi) has no organization and is read-only.
- One helper: the user's organization comes only from private.current_organization_id(). No query, rule or Edge Function reads it from the profile directly or takes it from what the browser sends. Today 12 places read the profile and 31 call a single-organization default; they move to the helper as they are touched.
- Real relations: Zite's link arrays become foreign keys (one-to-many) or proper link tables (many-to-many) with their own access rules. No JSON blobs for things we filter on.
- English, consistent names: tables and columns in English snake_case, as on Supabase today (companies, pratiche stays as the domain word); Italian only in what users see.
- History built in: created_at, updated_at, created_by, updated_by on every table; soft delete (removed_at) where users can delete; the audit log records the rest.
- Money and dates: amounts in cents (integer), dates as date, timestamps with time zone, as already decided for invoicing.
- Later, for other firms: memberships (user, organization, role), per-organization integration secrets in Vault, per-organization storage folders, organization switcher. Self-signup, billing and per-organization export only with a second customer.

Security and quality bar

Nothing ships unless the tests prove that the wrong person is refused, not only that the right person gets in.

- Guard test (032) on every change: every table has access rules, nothing privileged is callable without login, every bucket private with a size limit. Extended with: every business table has organization_id and an audit trigger.
- Isolation test: two organizations created in a rolled-back test; each sees none of the other's rows, files or functions.
- Role tests per feature: sign in as admin, manager, associate, segnalatore, client and anonymous; check what each is refused.
- Logic tests: today's 106 test files move with the code and run on every push (GitHub Actions), together with the database tests.
- Security advisor clean except the documented, accepted warnings.
- Audit log: one table, written by a trigger on every business table (who, when, which row, old and new values); readable by admins only.
- Observability: every Edge Function logs one structured line per request (action, user, organization, duration, outcome); a failed job or sync raises an alert email.
- Secrets: only in Supabase secrets and Vault, one per integration; the publishable key is the only key in the browser.
- Uploads: allowlisted types (PDF, images, docx, csv, xml, p7m), size limits, private buckets; malware scanning added with the client portal.

Operations

Everything reaches production through GitHub, never by hand, and a restore from backup has been rehearsed at least once.

Environment

What it is

Data

Local

Supabase CLI on the Mac, for building

Made-up seed data

Staging

Its own Supabase project, the app on a preview address; every pull request deploys here

A copy of production (decision open) or made-up data

Production

Supabase project gsnmtfugfhhrutmlvhzt, the app on Gemina's domain

Real data

- One repo holds the app, the Edge Functions, the migrations and the tests.
- Deploys: merge to main → GitHub Actions runs the tests, applies migrations, deploys the functions and publishes the static app. No chat or person connects to production to change it.
- Backups: Supabase daily backups (Pro plan); one restore drill into staging before go-live, then once a year.
- Access review: every quarter, check who has staff access and which keys exist.
- Costs at arrival: Supabase €20 a month; static hosting free; Zite €0.

Cleanups and changes on the way

These changes are part of the migration, done domain by domain as each one moves, so no domain is moved twice.

Cleanup

Why

When

Move data calls out of 155 components into hooks and domain API files

Screens stop depending on how data is fetched; one place to change it

As each domain moves

Replace the home-made cache (cacheDati.ts) and the 60-second freshness rule with TanStack Query

Standard caching, retries, loading and error states

M0, then per domain

Group code by feature (features/<domain>/) instead of by kind

Screen, hooks, API and server code of one domain sit together

As each domain moves

Hash routes to real URLs

Shareable, bookmarkable links

M0

Zite link arrays to foreign keys and link tables

Real relations, enforced by the database

With each domain's schema

Remove the Zite bridge (lib/supabase, 2.7k lines) and the 6 sync endpoints

They only exist to connect two systems

As each domain moves; gone at cutover

Remove dead invoice and commission code on Zite (PRDDISC-29)

Already replaced by Supabase

With the invoicing domain

Roles: one source (Supabase), the Zite Ruoli table and lib/permessi.ts retired; admin screen for roles and Reference Manager

Today two systems hold roles

With the admin domain

Storage rules move from "is staff" to permissions; signatures.send separate from signatures.manage

Finish the 12 Nov permission work

With signatures and files

Organization helper replaces the 43 direct or single-organization lookups

Memberships later become a one-place change

M0, then as touched

Unused tables (Soci, Bilanci, Layout schede, Scadenze milestone, Firme on Zite) moved as empty tables or merged with their Supabase twin

Keep features, drop duplicates

With their domain

Definition of done

The migration is finished when Zite is switched off and every box below is ticked.

- Every Gestionale screen and the segnalatori portal work on the new stack, checked in a browser by Giacomo
- All Zite data imported, row counts and invoice and commission totals reconciled against the 13 Nov export and a final export
- The 4 files stored only on Zite moved to storage
- Guard, isolation and role tests pass on every push; security advisor clean
- Audit log on every business table
- Code follows the layers above: no component calls the database, no rule only in the browser
- Deploys only through GitHub; Claude's production access revoked
- One restore drill done on staging
- Zite subscription cancelled

After that, in order: the client portal as a separate product (with malware scanning of uploads), then memberships and the multi-firm features when a second firm is real.
