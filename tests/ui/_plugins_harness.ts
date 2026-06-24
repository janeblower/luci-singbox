// Mirror of the pure helpers in lib/plugins.js. Keep in sync (a guard test in
// Plan 2's browser suite asserts the live module behaves identically).
export function collectOutboundTypes(plugins: any[]) {
  const out: [string, string][] = [];
  for (const p of plugins) if (p.api?.outboundTypes) out.push(...p.api.outboundTypes());
  return out;
}
export function collectTabs(plugins: any[]) {
  const out: any[] = [];
  for (const p of plugins) if (p.api?.tabs) out.push(...p.api.tabs());
  return out;
}
export function collectModes(plugins: any[]) {
  const out: any[] = [];
  for (const p of plugins) if (p.api?.mode) { const m = p.api.mode(); if (m) out.push(m); }
  return out;
}
