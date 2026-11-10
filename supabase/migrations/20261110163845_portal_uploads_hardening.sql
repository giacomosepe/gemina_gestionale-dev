-- Portale di caricamento fatture: più stretto prima che una pagina lo usi (revisione di sicurezza provvisoria, 10 nov 2026, punti 2 e 3).
-- 1) Bucket portal-uploads: 100 MB per file (era 500) e solo i tipi dichiarati ammessi per le fatture. Il tipo è dichiarato dal browser, quindi
--    la Edge Function controlla anche il contenuto dei primi byte alla conferma (vedi 2).
-- 2) Nuovo stato 'rejected' per i file il cui contenuto non corrisponde all'estensione (tolti dal bucket, mai copiati su Drive).
-- 3) Tentativi falliti con un codice di link non valido, per indirizzo (solo l'impronta HMAC dell'IP, mai l'IP in chiaro), per bloccare chi prova
--    a indovinare: la Edge Function rifiuta dopo 20 errori in 15 minuti. Tabella nello schema private: nessun accesso dall'API.

update storage.buckets
   set file_size_limit = 104857600,
       allowed_mime_types = array[
         'application/pdf',
         'application/xml', 'text/xml',
         'application/pkcs7-mime', 'application/x-pkcs7-mime', 'application/pkcs7-signature',
         'application/zip', 'application/x-zip-compressed',
         'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
         'text/csv', 'text/plain',
         'application/octet-stream'
       ]
 where id = 'portal-uploads';

alter table public.upload_portal_files drop constraint upload_portal_files_status_check;
alter table public.upload_portal_files add constraint upload_portal_files_status_check
  check (status in ('pending', 'uploaded', 'transferred', 'failed', 'rejected'));
comment on column public.upload_portal_files.status is 'pending = URL firmato dato, uploaded = nel bucket, transferred = copiato su Drive (e tolto dal bucket), failed = errore nel trasferimento, rejected = contenuto non corrispondente all''estensione (tolto dal bucket).';

create table private.portal_link_failures (
  ip_hash text        not null check (char_length(ip_hash) = 64),
  at      timestamptz not null default clock_timestamp()
);
comment on table private.portal_link_failures is 'Tentativi con un codice di link non valido sul portale di caricamento fatture (impronta HMAC dell''IP). Righe più vecchie di un giorno cancellate dalla Edge Function.';
create index portal_link_failures_ip_idx on private.portal_link_failures (ip_hash, at);
alter table private.portal_link_failures enable row level security;
revoke all on private.portal_link_failures from public, anon, authenticated;
