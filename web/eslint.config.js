// Layers: pages, components and ui never import the API client or Supabase directly; they go through hooks.
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist"] },
  ...tseslint.configs.recommended,
  {
    files: ["src/features/*/pages/**", "src/features/*/components/**", "src/ui/**", "src/app/**"],
    rules: {
      "no-restricted-imports": ["error", {
        patterns: [
          { group: ["**/shared/api/*", "@supabase/supabase-js"], message: "Call the API from a hook in features/<domain>/hooks, not from a page or component." },
        ],
      }],
    },
  },
);
