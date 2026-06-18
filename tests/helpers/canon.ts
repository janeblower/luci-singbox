// Mirror of the ucode-side tests/parity/canon: recursively sort object keys so
// parity comparison is key-order-agnostic. Arrays keep their order (order IS
// load-bearing for arrays in sing-box config).
export function canon<T>(value: T): T {
  if (Array.isArray(value)) return value.map(canon) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(value as Record<string, unknown>).sort()) {
      out[k] = canon((value as Record<string, unknown>)[k]);
    }
    return out as T;
  }
  return value;
}
