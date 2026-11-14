-- The signers of a signature attachment are 'client' and 'gemina' (were 'cliente' and 'gemina'): stored rows were rewritten in 20261114190000, the check follows.
alter table public.signature_attachments drop constraint signature_attachments_signers_check;
update public.signature_attachments set signers = array_replace(signers, 'cliente', 'client') where 'cliente' = any (signers);
alter table public.signature_attachments
  add constraint signature_attachments_signers_check check (cardinality(signers) between 1 and 2 and signers <@ array['client', 'gemina']);
