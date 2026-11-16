// The pure rules of the catalogue (ported from the Zite lib: categorie, fasi, campiInfo, dati). No database here, so they are unit-tested directly.
// Every message is Italian and shown to the person as it is.

export const DATA_TYPES = ["number", "text", "date", "yes_no", "choice", "money", "document", "multi_choice", "person"] as const;
export const FIELD_TYPES = ["number", "text", "date", "money", "choice", "multi_choice"] as const;
export const VALIDITIES = ["none", "months", "until_deadline", "until_next"] as const;
const WITH_OPTIONS = ["choice", "multi_choice"];

const same = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

export function categoryError(name: string, others: readonly { id: string; name: string }[], id?: string): string | null {
  const n = name.trim();
  if (!n) return "Il nome della categoria è obbligatorio.";
  if (n.length > 40) return "Il nome della categoria è troppo lungo (al massimo 40 caratteri).";
  if (others.some((c) => c.id !== id && same(c.name, n))) return `Esiste già la categoria “${n}”.`;
  return null;
}

export const categoryArchiveError = (activeServices: number): string | null =>
  activeServices > 0 ? `Ha ancora ${activeServices} ${activeServices === 1 ? "servizio attivo" : "servizi attivi"}: archivialo o spostalo prima.` : null;

export const categoryDeleteError = (services: number): string | null =>
  services > 0
    ? `Ha ${services} ${services === 1 ? "servizio collegato" : "servizi collegati"} (anche archiviati): spostali in un'altra categoria prima, oppure archivia la categoria.`
    : null;

export function milestoneError(name: string, others: readonly { id: string; name: string }[], id?: string): string | null {
  const n = name.trim();
  if (!n) return "Il nome della milestone è obbligatorio.";
  if (n.length > 60) return "Il nome della milestone è troppo lungo (al massimo 60 caratteri).";
  if (others.some((m) => m.id !== id && same(m.name, n))) return `Esiste già la milestone “${n}”.`;
  return null;
}

export const daysError = (days: number | null | undefined): string | null =>
  days == null || (Number.isInteger(days) && days >= 0 && days <= 3650) ? null : "I giorni devono essere un numero intero tra 0 e 3650.";

export const optionLines = (text: string | null | undefined): string[] =>
  (text ?? "").split("\n").map((l) => l.trim()).filter(Boolean);

/** The first problem with a field a category or service defines for its cases, or null. */
export function fieldError(
  d: { label: string; field_type: string | null; options: string | null; feeds: string | null | undefined },
  others: readonly { id: string; label: string; feeds: string | null }[],
  id?: string,
): string | null {
  const label = d.label.trim();
  if (!label) return "Dai un nome al campo.";
  if (others.some((o) => o.id !== id && same(o.label, label))) return `Esiste già un campo “${label}”.`;
  if (!d.field_type || !(FIELD_TYPES as readonly string[]).includes(d.field_type)) return "Scegli il tipo di campo.";
  if (WITH_OPTIONS.includes(d.field_type) && optionLines(d.options).length < 1) return "Indica almeno un’opzione (una per riga).";
  if (d.feeds) {
    if (d.feeds !== "commission_base") return "Questo campo non può alimentare altro.";
    if (d.field_type !== "money") return "Solo un importo (€) può alimentare la base della commissione.";
    if (others.some((o) => o.id !== id && o.feeds === d.feeds)) return "Un altro campo alimenta già la base della commissione: ne basta uno per categoria.";
  }
  return null;
}

export interface DataRequestShape {
  name: string; data_type: string | null; save_on_company: boolean; save_on_contact: boolean; save_on_deal: boolean; save_on_case: boolean;
  save_on_asset: boolean; options: string | null; validity: string | null; validity_months: number | null;
}

export const isPermanent = (d: Pick<DataRequestShape, "save_on_company" | "save_on_contact">) => d.save_on_company || d.save_on_contact;

/** The first problem with a data request, or null. */
export function dataRequestError(d: DataRequestShape, others: readonly { id: string; name: string }[], id?: string): string | null {
  const name = d.name.trim();
  if (!name) return "Dai un nome al dato.";
  if (others.some((o) => o.id !== id && same(o.name, name))) return `Esiste già un dato “${name}”.`;
  if (!d.data_type || !(DATA_TYPES as readonly string[]).includes(d.data_type)) return "Scegli il tipo di dato.";
  if (d.save_on_company && d.save_on_contact) return "Un dato permanente sta sull’azienda o sul contatto, non su entrambi.";
  if (isPermanent(d) && (d.save_on_deal || d.save_on_case)) return "Un dato permanente non può stare anche su trattativa o pratica.";
  if (!isPermanent(d) && !d.save_on_deal && !d.save_on_case) return "Scegli dove si salva il dato.";
  if (d.save_on_asset && isPermanent(d)) return "Un dato del bene si chiede su trattativa o pratica, non sull’azienda né sul contatto.";
  if (WITH_OPTIONS.includes(d.data_type) && optionLines(d.options).length < 1) return "Indica almeno un’opzione (una per riga).";
  if (d.validity === "months" && !(d.validity_months && d.validity_months > 0)) return "Indica per quanti mesi il documento resta valido.";
  return null;
}

/** New positions 10, 20, 30… after swapping the item with its neighbour; only the ones that change. Equal or missing positions never block a move. */
export function moveOrder<T extends { id: string; position: number }>(list: readonly T[], id: string, direction: "up" | "down"): { id: string; position: number }[] {
  const l = [...list];
  const i = l.findIndex((x) => x.id === id);
  const j = direction === "up" ? i - 1 : i + 1;
  if (i < 0 || j < 0 || j >= l.length) return [];
  [l[i], l[j]] = [l[j], l[i]];
  return l.flatMap((x, k) => (x.position !== (k + 1) * 10 ? [{ id: x.id, position: (k + 1) * 10 }] : []));
}
