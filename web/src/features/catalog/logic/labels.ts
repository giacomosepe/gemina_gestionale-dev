// Italian labels for the codes the catalogue stores in English.
export const FIELD_TYPE_LABELS: Record<string, string> = { number: "Numero", text: "Testo", date: "Data", money: "Importo (€)", choice: "Scelta", multi_choice: "Scelta multipla" };
export const DATA_TYPE_LABELS: Record<string, string> = { ...FIELD_TYPE_LABELS, yes_no: "Sì / No", document: "Documento", person: "Persona" };

/** Where a data request is saved, in words. */
export function savedOn(d: { save_on_company: boolean; save_on_contact: boolean; save_on_deal: boolean; save_on_case: boolean; save_on_asset: boolean }): string {
  const parts = [d.save_on_company && "azienda", d.save_on_contact && "contatto", d.save_on_deal && "trattativa", d.save_on_case && "pratica"].filter(Boolean) as string[];
  return parts.join(", ") + (d.save_on_asset ? " (uno per ogni bene)" : "");
}
