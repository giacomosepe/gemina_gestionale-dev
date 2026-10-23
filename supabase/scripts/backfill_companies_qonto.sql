-- One-off, idempotent backfill of companies.qonto_client_id and companies.vat_number from Zite Aziende (PRDDISC-3).
-- Source: workspace "Gemina Revenue System", table Aziende, fields "Qonto ID" and "P.IVA", read on 2026-10-23 (63 aziende).
-- Match: companies.zite_azienda_id = the Zite record id. A Zite value that is empty never overwrites a Supabase value, and a
-- row is touched only when its value differs, so running the script again changes nothing (differences_left in the report stays []).
-- Needs migration 20261023125510_companies_qonto_client.sql. Run as the database owner (SQL editor / MCP), not from a browser.

begin;

create temporary table zite_aziende (
  zite_azienda_id text primary key,
  name            text not null,
  qonto_id        text,
  piva            text
) on commit drop;

insert into zite_aziende (zite_azienda_id, name, qonto_id, piva) values
    ('1bff93ce-826d-46ee-a029-1e39be535dd1', 'ACCIUGA S.R.L.', null, null),
    ('63b54c03-a648-4db5-8f98-3ec3f0abed85', 'ADENES ITALIA S.R.L.', null, '12430210968'),
    ('2cf48b5f-e707-4d4f-9511-ccef79839b95', 'AMF SPA', null, '06256010965'),
    ('d3dd01d0-588d-4e67-ba63-ccb2a57a7164', 'ASIF SRL', null, '05052320263'),
    ('55ea546d-6305-45cd-8d7d-d7759fcb0147', 'AZORES GESTIONE DEI RISCHI S.R.L. (AZORES G.D.R. S.R.L.)', null, null),
    ('86336bf2-595f-4fdf-9434-bab2a18873d7', 'Appennino Food Group', null, '01840391203'),
    ('dd15ef2b-3d09-4b9a-a24d-38547f7ace49', 'B & C PROJECT SRL', null, null),
    ('862bd862-f5b5-4959-a262-e20b10ee91ca', 'BERGAMASCHI E VIMERCATI S.P.A.', null, null),
    ('d0f24abb-0941-4e9e-8c46-e9695ecad386', 'BILD DISTRIBUZIONE S.R.L.', null, null),
    ('2ad04330-a672-45e5-81d7-fb96d30bb7a9', 'Brusa Biscottificio Srl', null, '00219460029'),
    ('b4a81035-030f-4882-81b3-33630eb7e3bb', 'CAVEGIOVANNA SRL', null, '01425500038'),
    ('a861c80e-23fc-415c-ad16-6f466bb4b511', 'CHERRY CONSULT S.R.L.', null, null),
    ('e76f4efe-c7d6-46b1-be96-a6c87a1d5ed6', 'COMAT S.R.L.', null, null),
    ('5ee9e92f-0506-4337-ae2c-f2dc68be5b2e', 'COOPLA'' SOCIETA'' COOPERATIVA', null, null),
    ('ef87f819-8f97-418e-a9ba-45af247cda6e', 'COSTRUIRE VALORE SRL', null, '02675430462'),
    ('9f0e9b5d-8308-49b2-b5e6-f14e18659335', 'CSS S.R.L.', null, null),
    ('762d19ee-02ff-4482-97d4-3ec4d90b9682', 'DANIELE GRANZOTTO', null, null),
    ('9dd132bc-1a5d-4e3c-b00c-debb1f019dde', 'DOCTORAPP SRL', null, null),
    ('056877bd-9a23-4566-96b4-359bf75286f4', 'EDITORIALE DOMUS S.P.A.', '01a05d15-f3a8-72d3-9a4b-19d15dd60c61', '07835550158'),
    ('8482be93-6b45-4d79-bd76-5ed3eea8d52a', 'ELCHIM S.P.A.', null, '00844740159'),
    ('4ca54357-9617-4877-8776-ce9bb7fd8dd5', 'EMME ESSE M.S. S.R.L.', null, null),
    ('a68369ff-f85a-417e-9e78-25bb63419e4c', 'FERRARO - S.P.A.', null, null),
    ('367d81b5-e6d2-46d3-8329-f5676e37b475', 'G.T.B. DI TOMOLA GUGLIELMO GIULIANO & C. S.N.C', null, '01122290032'),
    ('a24338ca-ad6f-4e0c-8b3a-58931f9bd5b6', 'GGM GROUP S.R.L.', null, null),
    ('b11f16fd-ea9d-43b8-b970-550f1dccc12d', 'GIOVANARDI S.P.A.', null, null),
    ('09e7b5dd-4fcb-4d9f-b602-f0d36f92b0c5', 'GRUPPO A S.N.C. DI A. PIERINI E G. BRIOSCHI', null, null),
    ('2b20d5f6-fa1b-49af-929d-f68e15b22d00', 'GUARNITEC SRL', null, null),
    ('8f06dacb-9391-4ce0-a70f-f035978f0518', 'I.C.R S.P.A. INCISIONI CILINDRI ROTOCALCO', null, '00505560128'),
    ('c0a85437-6c74-42df-a905-c8369fee542b', 'INOX LAGHI S.R.L.', null, null),
    ('53228222-61c1-4a9e-a67a-52137f561d9f', 'LANIFICIO SUBALPINO SRL', null, '01869540029'),
    ('24c7509c-d232-47de-9d63-cf6cda47ce88', 'LASER GRAFICA DIGITAL S.R.L.', null, null),
    ('cedd0638-c5b9-455e-a7bb-750f8e22c0c5', 'LEGGETT & PLATT OFFICE COMPONENTS INTERNATIONAL S.R.L.', null, null),
    ('a2f8385f-a21b-4bf4-8711-09581f4d7b41', 'MADE BLACK SRL', '01a0f70f-262f-7c03-9d85-e3eab52cdb5e', '02424010169'),
    ('aee66b49-8ca8-4a7e-84cc-f2b8b0074e60', 'MANIFATTURA A. TESTORI DI G. S.P.A.', null, null),
    ('6034a18c-d771-4e87-a70b-5fe63cf469f6', 'MICRA SOFTWARE & SERVICES S.R.L.', null, null),
    ('11146750-317c-4ee3-a55a-d7f4a14a27b2', 'MICROCONTROL ELECTRONIC S.R.L.', null, null),
    ('7b93bd87-1bd3-4dab-afa8-06a676134ed0', 'MILANI S.R.L.', null, null),
    ('e3f18d80-db89-4391-8ecc-879cbe03b791', 'MINIGRIP - GRIP PAK - S.R.L.', null, null),
    ('9b328cd6-5c3e-4987-83a0-92a91fd05fec', 'Mac Impianti Srl', '01a080ed-0ab9-724a-8292-8387302b315c', '01716050032'),
    ('64825d90-b2f8-4b81-a636-f5dc3cfa120c', 'Macchi Serafino Srl', null, '02480060124'),
    ('8205ffd0-ef5d-41f0-86ed-317b800daa5a', 'Mamoli', null, '02426200032'),
    ('4998c857-28a5-4f5d-bd9a-6d350d6c1c21', 'Milano Management Consulting', null, '10672570156'),
    ('109db93f-4536-4d25-a340-cda9ea1e4543', 'NICMA COMPANY S.R.L SB', null, null),
    ('1d8af0a3-a036-461b-b25b-741f4d16b4e4', 'OAK GO AMW Srl', null, '03293880047'),
    ('c69757f1-7342-45c2-9e57-4292d992eb20', 'PIDIELLE S.P.A.', null, null),
    ('01c8ad2b-3083-4df9-b292-df49bcaef3aa', 'PLASTIGRAF TREVIGIANA S.R.L.', null, null),
    ('3a04f17e-da1c-4d27-90cb-4953e5214b29', 'Paini Rubinetterie', null, '00260150032'),
    ('a4d6b149-876e-4500-84f4-0e781c3a762a', 'Podartis', null, '03669600268'),
    ('1a654edc-8471-42da-a6ee-5ed30459a399', 'RDB & OPEN SYSTEMS S.R.L.', null, null),
    ('b157018f-316c-42ba-b928-b1caba513672', 'RONDIS S.R.L.', null, null),
    ('2debc518-22da-4323-a929-02b3f92c4ff4', 'ROSA ERMANDO S.P.A.', null, null),
    ('367ca6a1-a2be-429f-8fc1-f6515b9e2c0b', 'SACO COMBIMAR S.P.A.', null, null),
    ('8cb502aa-c9b5-4aa8-9a94-0d39c8f12654', 'SIMEC GROUP S.R.L.', null, null),
    ('3cc0f26c-4f7b-4486-bd9f-40c787326f85', 'STUDIO BOSCHIERO ALBERTO', null, null),
    ('2d06a86f-1034-4931-8336-414fdc232090', 'SYDEMA SYSTEMS DEVELOPMENT MANAGEMENT S.R.L.', null, null),
    ('74f59432-99cf-462a-9e4c-bf6c54e1926e', 'Stante & Ecotrans Srl', null, '01826820134'),
    ('9f202b00-0606-4f9c-9aa6-de4e3ad2e2fc', 'Stein Warz Srl', '01a080ef-f789-7ae5-a7e1-9ab8d6fea092', '00613510031'),
    ('39dc766b-e0e1-407a-8c4d-fa88a1ea92ad', 'T''A MILANO S.R.L.', null, null),
    ('2dbd5da9-57bb-4e00-b827-807fd165b0f9', 'TEK S.R.L. SB', null, null),
    ('b49700a8-79ca-45dc-ba5f-7e95d70c310d', 'TESSITURA ROSA SRL', null, '00187140025'),
    ('887d9b7d-8704-430d-a845-b6e04350aa38', 'Technowrapp', null, '03724550284'),
    ('5e6c21db-92a9-45fe-b824-82bb3189ef3e', 'VAS S.R.L.', null, null),
    ('0258c866-01ad-44da-bff5-781c9d86d711', 'WEBBIT S.R.L.', null, null);

-- 1. Backfill (nothing is overwritten with an empty value) ----------------------------------------------------------------------
update public.companies c
   set qonto_client_id = coalesce(nullif(btrim(z.qonto_id), ''), c.qonto_client_id),
       vat_number      = coalesce(nullif(btrim(z.piva), ''), c.vat_number)
  from zite_aziende z
 where c.zite_azienda_id = z.zite_azienda_id
   and (c.qonto_client_id is distinct from coalesce(nullif(btrim(z.qonto_id), ''), c.qonto_client_id)
     or c.vat_number      is distinct from coalesce(nullif(btrim(z.piva), ''), c.vat_number));

-- 2. Report (one row of json) -----------------------------------------------------------------------------------------------------
-- counts: Zite aziende with a Qonto ID = Supabase companies with qonto_client_id, or each gap is listed below
-- zite_not_in_supabase: in Zite, not in Supabase (with a Qonto ID they cannot get their invoices attached)
-- supabase_not_in_zite: in Supabase, not in Zite
-- differences_left: must be []
select jsonb_build_object(
  'counts', jsonb_build_object(
    'zite_aziende',                  (select count(*) from zite_aziende),
    'supabase_companies',            (select count(*) from public.companies),
    'zite_with_qonto_id',            (select count(*) from zite_aziende where nullif(btrim(qonto_id), '') is not null),
    'supabase_with_qonto_client_id', (select count(*) from public.companies where qonto_client_id is not null),
    'zite_with_piva',                (select count(*) from zite_aziende where nullif(btrim(piva), '') is not null),
    'supabase_with_vat_number',      (select count(*) from public.companies where vat_number is not null)),
  'zite_not_in_supabase', (select coalesce(jsonb_agg(jsonb_build_object('zite_azienda_id', z.zite_azienda_id, 'name', z.name,
                                  'qonto_id', z.qonto_id, 'piva', z.piva) order by z.name), '[]')
                             from zite_aziende z
                            where not exists (select 1 from public.companies c where c.zite_azienda_id = z.zite_azienda_id)),
  'supabase_not_in_zite', (select coalesce(jsonb_agg(jsonb_build_object('zite_azienda_id', c.zite_azienda_id, 'name', c.name,
                                  'qonto_client_id', c.qonto_client_id, 'vat_number', c.vat_number) order by c.name), '[]')
                             from public.companies c
                            where not exists (select 1 from zite_aziende z where z.zite_azienda_id = c.zite_azienda_id)),
  'differences_left', (select coalesce(jsonb_agg(jsonb_build_object('zite_azienda_id', c.zite_azienda_id, 'name', c.name)), '[]')
                         from public.companies c join zite_aziende z using (zite_azienda_id)
                        where (nullif(btrim(z.qonto_id), '') is not null and c.qonto_client_id is distinct from btrim(z.qonto_id))
                           or (nullif(btrim(z.piva), '') is not null and c.vat_number is distinct from btrim(z.piva)))
) as report;

commit;
