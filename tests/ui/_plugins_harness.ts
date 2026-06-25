// Mirror of the pure helpers in lib/plugins.js. Keep in sync (a guard test in
// Plan 2's browser suite asserts the live module behaves identically).
export function collectOutboundTypes(plugins: any[]) {
  const out: [string, string][] = [];
  for (const p of plugins)
    if (p.api?.outboundTypes) out.push(...p.api.outboundTypes());
  return out;
}
export function collectInboundTypes(plugins: any[]) {
  const out: [string, string][] = [];
  for (const p of plugins)
    if (p.api?.inboundTypes) out.push(...p.api.inboundTypes());
  return out;
}
export function collectTabs(plugins: any[]) {
  const out: any[] = [];
  for (const p of plugins) if (p.api?.tabs) out.push(...p.api.tabs());
  return out;
}
export function collectModes(plugins: any[]) {
  const out: any[] = [];
  for (const p of plugins)
    if (p.api?.mode) {
      const m = p.api.mode();
      if (m) out.push(m);
    }
  return out;
}

// Mirror of pluginStatusMap() in lib/plugins.js. Maps the RAW `plugins` rpcd
// list (every registered/installed plugin, regardless of enabled flag) into a
// name → { installed, enabled } lookup. The Plugins tab uses this to keep the
// "Install" and "Enable" buttons independent: a plugin can be installed (present
// on disk → in the list) but not yet enabled. Deriving "installed" from the
// enabled-only loadEnabled() list (the old bug) made Enable unreachable.
export function pluginStatusMap(rawPlugins: any[]) {
  const m: Record<string, { installed: boolean; enabled: boolean }> = {};
  for (const p of rawPlugins || [])
    if (p?.name)
      m[p.name] = { installed: p.installed !== false, enabled: !!p.enabled };
  return m;
}
