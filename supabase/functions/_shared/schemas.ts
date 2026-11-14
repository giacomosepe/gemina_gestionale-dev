// Zod pieces shared by the actions. The input of every action is a Zod schema; nothing reaches a handler unchecked.
import { z } from "npm:zod@3.23.8";

export { z };

export const uuid = z.string().uuid();
export const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");
export const nonEmpty = z.string().trim().min(1);

export const pagination = z.object({
  offset: z.number().int().min(0).default(0),
  limit: z.number().int().min(1).max(200).default(50),
});

export const noInput = z.object({}).strict();
