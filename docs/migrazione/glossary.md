# English names

Every table, column, enum value, function and file name is English. Only text that users read stays Italian. Approved by Giacomo on 13 Nov 2026 (Linear PM-191).

| Italian | English | Notes |
| -- | -- | -- |
| azienda | company | table `companies` already exists |
| contatto, persona | contact | |
| trattativa | deal | |
| attività | activity | |
| lead | lead | |
| lista | list | |
| campagna | campaign | |
| obiettivo | target | |
| notifica | notification | |
| pratica | case | table `pratiche` becomes `cases` |
| scadenza | deadline | table `scadenze` becomes `deadlines` |
| bene | asset | `beni`, `bene_values`, `bene_documents` become `assets`, `asset_values`, `asset_documents` |
| fattura | invoice | |
| provvigione | commission | |
| segnalatore | referrer | the existing table `partners` keeps its name |
| segnalazione | referral | |
| strumento, servizio | service | |
| categoria | category | |
| fase | phase | |
| milestone | milestone | |
| bando | grant_call | |
| dati da raccogliere | data_requests | |
| firma | signature | |
| fornitore | supplier | |
| bilancio | financial_statement | |
| socio | shareholder | |
| messaggio | message | |
| liquidazione IVA | vat_settlement | already named so |

## Rules

- Names are `snake_case`, plural for tables, singular for columns.
- Money columns end in `_cents`, dates in `_on`, timestamps in `_at`.
- Enum values are English words (`open`, `won`, `lost`), with the Italian label kept in one place in the app.
- The import runner holds the one map from old Zite names to new names.
- A guard test fails when a table or column name contains a glossary word in Italian.
