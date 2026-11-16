// catalogo: entry point. The actions are in actions.ts (so tests can import them without starting a server).
import { serve } from "../_shared/serve.ts";
import { catalogo } from "./actions.ts";

serve(catalogo);
