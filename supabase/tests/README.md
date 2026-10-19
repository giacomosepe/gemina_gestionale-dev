# Tests (to write next)

Run inside a transaction that rolls back, as each kind of user. Checklist to cover first
(from `claude/2026-10-19-piano-messaggi-commenti-supabase.md`, section 8):

- Two referrers A and B: A cannot read, write, mark read or create a conversation for B.
- A referrer cannot insert `internal = true`; internal notes never reach referrers (reads, previews, unread counts, Realtime).
- A signed-in user with no memberships sees nothing.
- Staff see all conversations and notes.
- Send limit fires (P0429) after 20 messages in a minute.
- An archived referrer loses access at the next bridge call.
