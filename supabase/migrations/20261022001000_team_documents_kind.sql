-- A third kind of scope: 'team' = Gemina's own files about a pratica (attachments of the azioni, 2026-10-22), seen by staff only.
-- On its own file because a new enum value cannot be used in the same transaction that adds it (20261022001100 uses it).
-- private.can_access_scope already returns staff-only for any kind other than client/partner, so nothing else changes here.
alter type public.conversation_kind add value if not exists 'team';
