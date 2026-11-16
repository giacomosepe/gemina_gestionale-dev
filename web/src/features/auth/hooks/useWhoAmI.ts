// Calls the sample function `ping`: proves the chain session -> function -> database as the user.
import { useQuery } from "@tanstack/react-query";
import { callFunction } from "../../../shared/api/client";
import { useSession } from "./SessionProvider";

export interface WhoAmI { staffRole: string | null; organizationId: string | null }

export function useWhoAmI() {
  const { session } = useSession();
  return useQuery({
    queryKey: ["whoami", session?.user.id],
    queryFn: () => callFunction<WhoAmI>("ping", "whoami"),
    enabled: Boolean(session),
    retry: false,
  });
}
