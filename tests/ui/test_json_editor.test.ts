import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadLuciModule } from "../helpers/luci";

// The JSON editor applies a DIFF, not an overwrite.
//
// import_section hands back `fields` (what the JSON carried), `known` (every
// option the descriptor COULD produce) and `extra` (keys it does not model). From
// those, applyImport must:
//   * write the fields the JSON carried,
//   * REMOVE the `known` ones it dropped — that is how a field is cleared, and it
//     is why an unset flag never has to be written back as "0",
//   * leave everything NOT in `known` completely alone: enabled, builtin,
//     nft_rules, the whole sub_* family have no JSON representation, and a full
//     overwrite would wipe them,
//   * treat a changed `tag` as a RENAME of this section — never a second section
//     with the original left behind — dragging every by-name reference with it.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

interface UciSection {
  ".name": string;
  [k: string]: unknown;
}

interface JsonEditorMod {
  hasJson: (kind: string, sid: string) => boolean;
  tagError: (sid: string, tag: string) => string | null;
  applyImport: (
    kind: string,
    sid: string,
    r: {
      fields?: Record<string, unknown>;
      known?: string[];
      extra?: Record<string, unknown>;
      tag?: string | null;
    },
  ) => string;
}

function evalModule(file: string, extra: Record<string, unknown>) {
  return loadLuciModule(resolve(VIEW_ROOT, file), {
    _: (s: string) => Object.assign(String(s), { format: () => String(s) }),
    form: { Button: "Button" },
    ui: { showModal: () => {}, hideModal: () => {}, addNotification: () => {} },
    E: () => ({}),
    ...extra,
  }).exports as Record<string, unknown>;
}

function load(state: Record<string, UciSection>) {
  const uci = {
    get: (_cfg: string, sid: string, opt?: string) =>
      opt === undefined ? (state[sid] ?? null) : (state[sid]?.[opt] ?? null),
    set: (_cfg: string, sid: string, opt: string, val: unknown) => {
      state[sid] = state[sid] ?? { ".name": sid };
      state[sid][opt] = val;
    },
    unset: (_cfg: string, sid: string, opt: string) => {
      if (state[sid]) delete state[sid][opt];
    },
    sections: (_cfg: string, stype?: string) =>
      Object.values(state).filter((s) => !stype || s[".type"] === stype),
  };

  // NOTE: no `rename` on the uci stub — the real LuCI uci API has none, which is
  // exactly what this used to hide. SbCommon.renameSection is the seam now.
  const renamed: [string, string][] = [];
  const mod = evalModule("lib/json_editor.js", {
    uci,
    SbRpc: {},
    SbCommon: {
      renameSection: (sid: string, to: string) => {
        const sec = state[sid];
        if (!sec) return false;
        delete state[sid];
        sec[".name"] = to;
        state[to] = sec;
        renamed.push([sid, to]);
        return true;
      },
      showJsonModal: () => {},
    },
  }) as unknown as JsonEditorMod;

  return { mod, renamed };
}

// A vless outbound with UCI-only settings the JSON knows nothing about.
function fixture(): Record<string, UciSection> {
  return {
    v1: {
      ".name": "v1",
      ".type": "outbound",
      enabled: "1",
      type: "vless",
      server: "old.example",
      server_port: "443",
      server_uuid: "u",
      tls_enabled: "1",
      tls_server_name: "sni.old",
      // UCI-only — no json_key anywhere, so never in `known`.
      sub_cache_persist: "1",
    },
    sub1: {
      ".name": "sub1",
      ".type": "outbound",
      type: "subscription",
      sub_url: "https://x/y",
    },
    grp: {
      ".name": "grp",
      ".type": "outbound",
      type: "selector",
      group_outbounds: ["v1", "other"],
    },
    rr: { ".name": "rr", ".type": "route_rule", outbound: "v1" },
  };
}

const KNOWN = [
  "server",
  "server_port",
  "server_uuid",
  "tls_enabled",
  "tls_server_name",
  "tls_insecure",
  "transport_type",
];

describe("hasJson", () => {
  it("is false only for a subscription outbound", () => {
    const { mod } = load(fixture());
    expect(mod.hasJson("outbound", "v1")).toBe(true);
    expect(mod.hasJson("outbound", "sub1")).toBe(false);
    expect(mod.hasJson("route_rule", "rr")).toBe(true);
    expect(mod.hasJson("dns_server", "anything")).toBe(true);
    expect(mod.hasJson("cache", "anything")).toBe(false); // not a JSON kind
  });
});

describe("tagError", () => {
  it("accepts an unchanged tag and a free name", () => {
    const { mod } = load(fixture());
    expect(mod.tagError("v1", "v1")).toBeNull();
    expect(mod.tagError("v1", "tokyo")).toBeNull();
  });

  it("rejects a name already taken by ANY section", () => {
    const { mod } = load(fixture());
    // UCI names share one namespace per config file.
    expect(mod.tagError("v1", "grp")).not.toBeNull();
  });

  it("rejects a name UCI cannot hold", () => {
    const { mod } = load(fixture());
    expect(mod.tagError("v1", "has spaces")).not.toBeNull();
    expect(mod.tagError("v1", "../etc")).not.toBeNull();
  });
});

describe("applyImport", () => {
  it("writes the changed fields and leaves UCI-only options alone", () => {
    const state = fixture();
    const { mod } = load(state);

    mod.applyImport("outbound", "v1", {
      fields: {
        server: "new.example",
        server_port: "8443",
        server_uuid: "u",
        tls_enabled: "1",
        tls_server_name: "sni.old",
      },
      known: KNOWN,
      extra: {},
      tag: "v1",
    });

    expect(state.v1.server).toBe("new.example");
    expect(state.v1.server_port).toBe("8443");
    // Never in `known` — a JSON edit must not be able to disable the outbound or
    // throw away its subscription settings.
    expect(state.v1.enabled).toBe("1");
    expect(state.v1.sub_cache_persist).toBe("1");
    expect(state.v1.type).toBe("vless");
  });

  it("removes a known field the JSON dropped — that is how you clear one", () => {
    const state = fixture();
    const { mod } = load(state);

    // The user deleted the whole tls block.
    mod.applyImport("outbound", "v1", {
      fields: { server: "old.example", server_port: "443", server_uuid: "u" },
      known: KNOWN,
      extra: {},
      tag: "v1",
    });

    expect(state.v1).not.toHaveProperty("tls_enabled");
    expect(state.v1).not.toHaveProperty("tls_server_name");
    expect(state.v1.enabled).toBe("1"); // still untouched
  });

  it("stores unknown keys in json_extra, and clears it when they go away", () => {
    const state = fixture();
    const { mod } = load(state);

    mod.applyImport("outbound", "v1", {
      fields: { server: "old.example" },
      known: KNOWN,
      extra: { some_future_key: { nested: [1, 2] } },
      tag: "v1",
    });
    expect(JSON.parse(state.v1.json_extra as string)).toEqual({
      some_future_key: { nested: [1, 2] },
    });

    mod.applyImport("outbound", "v1", {
      fields: { server: "old.example" },
      known: KNOWN,
      extra: {},
      tag: "v1",
    });
    expect(state.v1).not.toHaveProperty("json_extra");
  });

  it("a changed tag RENAMES the section and rewrites the references to it", () => {
    const state = fixture();
    const { mod, renamed } = load(state);

    const sid = mod.applyImport("outbound", "v1", {
      fields: { server: "old.example" },
      known: KNOWN,
      extra: {},
      tag: "tokyo",
    });

    expect(sid).toBe("tokyo");
    // The original must NOT survive alongside a new one.
    expect(state.v1).toBeUndefined();
    expect(state.tokyo).toBeDefined();
    expect(state.tokyo.server).toBe("old.example");
    // …and it goes through renameSection(), which is what drags every by-name
    // reference along (the backend silently drops dangling ones).
    expect(renamed).toEqual([["v1", "tokyo"]]);
  });

  it("writes a list field as a list", () => {
    const state = fixture();
    const { mod } = load(state);

    mod.applyImport("route_rule", "rr", {
      fields: { domain_suffix: [".ru", ".su"] },
      known: ["domain_suffix", "outbound"],
      extra: {},
      tag: null,
    });

    expect(state.rr.domain_suffix).toEqual([".ru", ".su"]);
    // `outbound` was in `known` but not in the JSON -> cleared.
    expect(state.rr).not.toHaveProperty("outbound");
  });
});
