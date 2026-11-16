// The shapes the `catalogo` function returns (see supabase/functions/catalogo/actions.ts).
export interface Category { id: string; name: string; position: number; active: boolean; macro_category: string | null; standard_terms: string | null; services: number; active_services: number }
export interface Milestone { id: string; name: string; position: number; active: boolean; days: number | null }
export interface DataRequest {
  id: string; name: string; data_type: string | null; lifetime: string | null; save_on_company: boolean; save_on_contact: boolean; save_on_deal: boolean; save_on_case: boolean;
  save_on_asset: boolean; required_by_default: boolean; options: string | null; help: string | null; archived: boolean; uses: number; used_in: string[];
}
export interface ServiceField {
  id: string; label: string; field_type: string | null; options: string | null; required: boolean; initial_value: string | null; help: string | null;
  position: number; active: boolean; feeds: string | null; inherited: boolean;
}
export type Direction = "up" | "down";
