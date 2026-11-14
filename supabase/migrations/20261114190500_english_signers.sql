-- Signers of the signature attachments: 'cliente' becomes 'client'.
-- Order matters: the old check constraint goes first (it rejects 'client'), and the user triggers are paused during the update, because
-- private.signature_attachments_before_write puts the old signers back on rows already sent or signed, which would leave 'cliente' in them.
alter table public.signature_attachments drop constraint signature_attachments_signers_check;
alter table public.signature_attachments disable trigger user;
update public.signature_attachments set signers = array_replace(signers, 'cliente', 'client') where 'cliente' = any (signers);
alter table public.signature_attachments enable trigger user;
alter table public.signature_attachments add constraint signature_attachments_signers_check check (cardinality(signers) between 1 and 2 and signers <@ array['client', 'gemina']);
