// The import steps, in dependency order. Each domain adds its own here when its schema exists (PM-153 catalogue first, then companies, CRM, cases ...).
// A step maps one Zite table to one new table; its Zite id goes to `legacy_id`. See types.ts.
import type { Step } from "./types.ts";

export const steps: Step[] = [];
