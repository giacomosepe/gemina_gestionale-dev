// Name of the connected Supabase project (the first part of its address), for the "in costruzione" footer.
export const environmentName: string | undefined = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.replace("https://", "").split(".")[0];
