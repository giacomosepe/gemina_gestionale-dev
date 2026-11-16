import { deepStrictEqual as assertEquals } from "node:assert/strict";
import { categoryArchiveError, categoryError, dataRequestError, daysError, fieldError, milestoneError, moveOrder } from "./rules.ts";

const dr = { name: "Fatturato", data_type: "money", save_on_company: false, save_on_contact: false, save_on_deal: false, save_on_case: true, save_on_asset: false, options: null, validity: null, validity_months: null };

Deno.test("category names: required, length, duplicates ignoring case, own name allowed", () => {
  const others = [{ id: "a", name: "SIMEST" }];
  assertEquals(categoryError("  ", others), "Il nome della categoria è obbligatorio.");
  assertEquals(categoryError("x".repeat(41), others)?.includes("troppo lungo"), true);
  assertEquals(categoryError("simest", others), "Esiste già la categoria “simest”.");
  assertEquals(categoryError("SIMEST", others, "a"), null);
});

Deno.test("category archive message is singular and plural", () => {
  assertEquals(categoryArchiveError(0), null);
  assertEquals(categoryArchiveError(1)?.startsWith("Ha ancora 1 servizio attivo"), true);
  assertEquals(categoryArchiveError(3)?.startsWith("Ha ancora 3 servizi attivi"), true);
});

Deno.test("milestones and days", () => {
  assertEquals(milestoneError("", []), "Il nome della milestone è obbligatorio.");
  assertEquals(milestoneError("Invio", [{ id: "1", name: "invio" }]), "Esiste già la milestone “Invio”.");
  assertEquals(daysError(null), null);
  assertEquals(daysError(30), null);
  assertEquals(daysError(-1) !== null, true);
  assertEquals(daysError(1.5) !== null, true);
});

Deno.test("fields: type, options, commission base", () => {
  const f = { label: "Importo", field_type: "money", options: null, feeds: null };
  assertEquals(fieldError(f, []), null);
  assertEquals(fieldError({ ...f, field_type: "choice" }, []), "Indica almeno un’opzione (una per riga).");
  assertEquals(fieldError({ ...f, field_type: null }, []), "Scegli il tipo di campo.");
  assertEquals(fieldError({ ...f, feeds: "commission_base" }, []), null);
  assertEquals(fieldError({ ...f, field_type: "text", feeds: "commission_base" }, [])?.includes("importo"), true);
  assertEquals(fieldError({ ...f, feeds: "commission_base" }, [{ id: "z", label: "Altro", feeds: "commission_base" }])?.includes("ne basta uno"), true);
  assertEquals(fieldError({ ...f, feeds: "boh" }, []), "Questo campo non può alimentare altro.");
});

Deno.test("data requests: where it is saved", () => {
  assertEquals(dataRequestError(dr, []), null);
  assertEquals(dataRequestError({ ...dr, save_on_case: false }, []), "Scegli dove si salva il dato.");
  assertEquals(dataRequestError({ ...dr, save_on_company: true, save_on_contact: true }, [])?.includes("non su entrambi"), true);
  assertEquals(dataRequestError({ ...dr, save_on_company: true }, [])?.includes("non può stare anche"), true);
  assertEquals(dataRequestError({ ...dr, save_on_asset: true, save_on_contact: true, save_on_case: false }, [])?.includes("del bene"), true);
  assertEquals(dataRequestError({ ...dr, data_type: "choice" }, []), "Indica almeno un’opzione (una per riga).");
  assertEquals(dataRequestError({ ...dr, validity: "months" }, [])?.includes("quanti mesi"), true);
});

Deno.test("moveOrder renumbers 10, 20, 30 and writes only what changes", () => {
  const l = [{ id: "a", position: 0 }, { id: "b", position: 0 }, { id: "c", position: 0 }];
  assertEquals(moveOrder(l, "b", "up"), [{ id: "b", position: 10 }, { id: "a", position: 20 }, { id: "c", position: 30 }]);
  assertEquals(moveOrder(l, "a", "up"), []);
  assertEquals(moveOrder(l, "c", "down"), []);
  const ordered = [{ id: "a", position: 10 }, { id: "b", position: 20 }, { id: "c", position: 30 }];
  assertEquals(moveOrder(ordered, "a", "down"), [{ id: "b", position: 10 }, { id: "a", position: 20 }]);
});
