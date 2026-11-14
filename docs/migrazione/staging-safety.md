# Staging safety with real data (PM-152)

Staging (`geminup-staging`) may hold a copy of the real data (CLAUDE.md rule 6). It must not be able to reach real people or real accounts.

| Channel | State on staging | Where it is enforced |
|---|---|---|
| Email (Resend) | Every recipient, referrer or team, must be on `DEV_TEST_PARTNER_EMAILS`; anything else is dropped and logged. Allowlist: giacomo@giacomosepe.com, giacomo.sepe@icloud.com. `PARTNER_EMAILS_REAL` stays unset. | `recipientAllowed()` in `message-emails`, checked inside `send()` |
| Qonto | The sync only reads (GET) and `QONTO_LOGIN` is unset. Qonto sync is not part of the new version. | `qonto-sync`; no write call exists |
| Drive | No Edge Function writes to Drive today. Imported rows keep real folder ids: when a Drive step is built, it takes a root folder setting and staging points to a test folder. | to build (see admin panel) |
| Sign-in | Sign-ups off; no auth users except Giacomo. The import runner must not create auth users for the people in the data. | Supabase Auth settings; import runner (M1) |
| Secrets | Separate from production; only in Supabase secrets/Vault, never in the repo. | CLAUDE.md rule 5 |

## Settings move to the admin panel (decided 14 Nov)

Accounts and the allowlist are set by an admin in the app (PM-175), not as dashboard secrets: email account and senders, Qonto, Drive root folder, app and portal URLs, the project mode (staging or live) and the test allowlist. Secret values are write-only (Vault). Until the panel exists, the Edge Function secrets above stand in for it, and the check in `send()` keeps the same meaning: outside live, only the allowlist.

## Checklist before real data is loaded
- [ ] `DEV_TEST_PARTNER_EMAILS` set on staging; function deployed.
- [ ] Trigger each email path (referrer reply, team digest, reminders) and see nothing leave the allowlist.
- [ ] `PARTNER_EMAILS_REAL`, `QONTO_LOGIN` unset.
- [ ] Auth: sign-ups off; only Giacomo's user exists.
- [ ] Cloudflare Access in front of the staging app.
