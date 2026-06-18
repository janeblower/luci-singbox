import { afterAll, beforeAll } from "bun:test";
import { closeConnection, warmConnection } from "./ssh.ts";

// Call inside a describe() block in any backend/parity test that needs the
// guest. Keeps host-only ui/cross tests free of the guest connection.
export function useGuest(): void {
  beforeAll(() => warmConnection());
  afterAll(() => closeConnection());
}
