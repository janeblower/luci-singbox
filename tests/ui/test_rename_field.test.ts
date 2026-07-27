import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadLuciModule } from "../helpers/luci";

// Regression for the "Name is only settable at creation" bug.
//
// addRenameField() used to attach __rename with the untabbed s.option(). Every
// grid section in this UI is tabbed, and LuCI only renders options that carry a
// tab — so the field existed in the form model but never appeared in the modal.
// It must now go through s.taboption(<first tab>, ...).
//
// Second half: a rename that doesn't rewrite the references to the old name
// leaves a dangling ref that the backend silently drops (route.uc warns and
// removes the rule). renameRefs() must rewrite them in the same changeset.
//
// THE STUB BELOW DELIBERATELY HAS NO `rename` METHOD. The real LuCI uci API has
// none — createSID/resolveSID/add/clone/remove/get/set/unset/sections/move, and
// "rename" only in doc comments — but this stub used to provide one, so it
// validated the author's idea of LuCI instead of LuCI. `uci.rename(...)` threw a
// TypeError on every real router while this file stayed green. Do not add one.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

type Opt = Record<string, unknown>;

interface Section {
  sectiontype: string;
  parse(): Promise<unknown>;
  addModalOptions?: (s: Section) => unknown;
  option(widget: unknown, name: string): Opt;
  taboption(tab: string, widget: unknown, name: string): Opt;
}

interface UciSection {
  ".name": string;
  [k: string]: unknown;
}

// A uci stub that models the METHODS the real LuCI uci.js exposes. Insertion
// order stands in for `.index` (uci.sections() returns file order, which is
// evaluation order for route/dns rules).
function loadCommon(state: Record<string, UciSection>) {
  const uci = {
    get: (_cfg: string, sid: string, opt?: string) =>
      opt === undefined ? (state[sid] ?? null) : (state[sid]?.[opt] ?? null),
    set: (_cfg: string, sid: string, opt: string, val: unknown) => {
      if (!state[sid]) return; // uci.set() on a removed section is a no-op
      state[sid][opt] = val;
    },
    add: (_cfg: string, stype: string, name: string) => {
      state[name] = { ".name": name, ".type": stype };
      return name;
    },
    remove: (_cfg: string, sid: string) => {
      delete state[sid];
    },
    move: (_cfg: string, sid1: string, sid2: string, after?: boolean) => {
      const names = Object.keys(state);
      const s1 = state[sid1];
      if (!s1 || !state[sid2]) return false;
      const rest = names.filter((n) => n !== sid1);
      const at = rest.indexOf(sid2) + (after ? 1 : 0);
      rest.splice(at, 0, sid1);
      const reordered: Record<string, UciSection> = {};
      for (const n of rest) reordered[n] = state[n];
      for (const n of names) delete state[n];
      Object.assign(state, reordered);
      return true;
    },
    sections: (_cfg: string, stype?: string) =>
      Object.values(state).filter((s) => !stype || s[".type"] === stype),
  };

  const common = loadLuciModule(resolve(VIEW_ROOT, "lib/common.js"), {
    _: (s: unknown) => s,
    form: { Value: "Value", ListValue: "ListValue" },
    uci,
    ui: {},
    SbRpc: {},
    E: () => ({}),
    window: {},
    document: {},
  }).exports as {
    addRenameField: (s: Section, tab?: string) => void;
    renameRefs: (kind: string, from: string, to: string) => void;
    renameSection: (oldSid: string, newName: string) => boolean;
  };
  return { common, uci };
}

// Minimal CBI section stub that records how each option was registered.
function makeSection(sectiontype: string) {
  const registered: { via: string; tab?: string; name: string; opt: Opt }[] =
    [];
  const s: Section & { registered: typeof registered } = {
    sectiontype,
    registered,
    parse: () => Promise.resolve(),
    option(_w: unknown, name: string) {
      const opt: Opt = {};
      registered.push({ via: "option", name, opt });
      return opt;
    },
    taboption(tab: string, _w: unknown, name: string) {
      const opt: Opt = {};
      registered.push({ via: "taboption", tab, name, opt });
      return opt;
    },
  };
  return s;
}

describe("addRenameField", () => {
  it("registers __rename through taboption so a tabbed modal renders it", () => {
    const { common } = loadCommon({});
    const s = makeSection("outbound");
    common.addRenameField(s, "basic");

    expect(s.registered).toHaveLength(1);
    expect(s.registered[0].via).toBe("taboption");
    expect(s.registered[0].tab).toBe("basic");
    expect(s.registered[0].name).toBe("__rename");
    expect(s.registered[0].opt.modalonly).toBe(true);
  });

  it("rejects a name already taken by ANY section, not just same-kind siblings", () => {
    const { common } = loadCommon({
      dns_google: { ".name": "dns_google", ".type": "dns_server" },
    });
    const s = makeSection("outbound");
    common.addRenameField(s, "basic");
    const validate = s.registered[0].opt.validate as (
      sid: string,
      v: string,
    ) => true | string;

    // UCI section names share one namespace per config file: an outbound may
    // not take a dns_server's name.
    expect(validate("vless_out", "dns_google")).not.toBe(true);
    expect(validate("vless_out", "free_name")).toBe(true);
    expect(validate("vless_out", "vless_out")).toBe(true);
  });

  it("write() only stages the rename; parse() applies it", async () => {
    // LuCI parses options in DECLARATION order and "Name" is declared first, so
    // renaming inside write() would leave every following option writing into a
    // section id that no longer exists. uci.set() on a removed section returns
    // silently, so the rest of the modal's edits would evaporate without a word.
    const state: Record<string, UciSection> = {
      vless_out: { ".name": "vless_out", ".type": "outbound" },
      rr: { ".name": "rr", ".type": "route_rule", outbound: "vless_out" },
    };
    const { common } = loadCommon(state);
    const s = makeSection("outbound");
    common.addRenameField(s, "basic");
    const write = s.registered[0].opt.write as (sid: string, v: string) => void;

    write("vless_out", "tokyo");
    // Nothing has moved yet — a sibling option can still write to its section.
    expect(state.vless_out).toBeDefined();
    expect(state.tokyo).toBeUndefined();
    state.vless_out.server = "1.2.3.4";

    await s.parse();

    expect(state.vless_out).toBeUndefined();
    expect(state.tokyo.server).toBe("1.2.3.4"); // the sibling edit survived
    expect(state.rr.outbound).toBe("tokyo");
  });

  it("arms the modal section too, since a grid clones the options not the section", async () => {
    const state: Record<string, UciSection> = {
      a: { ".name": "a", ".type": "outbound" },
    };
    const { common } = loadCommon(state);
    const s = makeSection("outbound");
    common.addRenameField(s, "basic");

    // What LuCI's renderMoreOptionsModal does: fresh section, cloned options,
    // then addModalOptions(modalSection).
    const modal = makeSection("outbound");
    (s.addModalOptions as (m: Section) => unknown)(modal);

    (s.registered[0].opt.write as (sid: string, v: string) => void)("a", "b");
    await modal.parse();

    expect(state.b).toBeDefined();
    expect(state.a).toBeUndefined();
  });

  it("write() is a no-op when the name is unchanged", async () => {
    const state: Record<string, UciSection> = {
      rs: { ".name": "rs", ".type": "ruleset" },
      rr: { ".name": "rr", ".type": "route_rule", rule_set: ["rs"] },
    };
    const { common } = loadCommon(state);
    const s = makeSection("ruleset");
    common.addRenameField(s, "basic");
    const write = s.registered[0].opt.write as (sid: string, v: string) => void;

    write("rs", "rs");
    await s.parse();
    expect(state.rs).toBeDefined();
    expect(state.rr.rule_set).toEqual(["rs"]);
  });
});

describe("renameSection", () => {
  it("carries the section's options across and drops the old id", () => {
    const state: Record<string, UciSection> = {
      vless_out: {
        ".name": "vless_out",
        ".type": "outbound",
        server: "1.2.3.4",
        tls_alpn: ["h2", "http/1.1"],
      },
      grp: {
        ".name": "grp",
        ".type": "outbound",
        group_outbounds: ["vless_out", "other_out"],
        group_default: "vless_out",
      },
      rr: { ".name": "rr", ".type": "route_rule", outbound: "vless_out" },
      rd: { ".name": "rd", ".type": "route_default", outbound: "vless_out" },
      untouched: {
        ".name": "untouched",
        ".type": "route_rule",
        outbound: "other_out",
      },
    };
    const { common } = loadCommon(state);

    expect(common.renameSection("vless_out", "tokyo")).toBe(true);

    expect(state.vless_out).toBeUndefined();
    expect(state.tokyo[".type"]).toBe("outbound");
    expect(state.tokyo.server).toBe("1.2.3.4");
    expect(state.tokyo.tls_alpn).toEqual(["h2", "http/1.1"]);
    expect(state.grp.group_outbounds).toEqual(["tokyo", "other_out"]);
    expect(state.grp.group_default).toBe("tokyo");
    expect(state.rr.outbound).toBe("tokyo");
    expect(state.rd.outbound).toBe("tokyo");
    expect(state.untouched.outbound).toBe("other_out");
  });

  it("keeps the section where it was — route rules are evaluated in file order", () => {
    // uci.add() appends. Without the move() a renamed route rule would silently
    // drop to the bottom of the chain and stop matching what it used to match.
    const state: Record<string, UciSection> = {
      r1: { ".name": "r1", ".type": "route_rule" },
      r2: { ".name": "r2", ".type": "route_rule" },
      r3: { ".name": "r3", ".type": "route_rule" },
    };
    const { common } = loadCommon(state);
    common.renameSection("r2", "middle");
    expect(Object.keys(state)).toEqual(["r1", "middle", "r3"]);
  });

  it("rewrites a self-reference, which is why refs are done after the copy", () => {
    const state: Record<string, UciSection> = {
      chain: {
        ".name": "chain",
        ".type": "route_rule",
        rules: ["chain", "other"],
      },
    };
    const { common } = loadCommon(state);
    common.renameSection("chain", "chain2");
    expect(state.chain2.rules).toEqual(["chain2", "other"]);
  });
});

describe("renameRefs", () => {
  it("rewrites rule_set list references on both route and dns rules", () => {
    const state: Record<string, UciSection> = {
      russia_inside: { ".name": "russia_inside", ".type": "ruleset" },
      rr: {
        ".name": "rr",
        ".type": "route_rule",
        rule_set: ["russia_inside", "discord"],
      },
      dr: { ".name": "dr", ".type": "dns_rule", rule_set: "russia_inside" },
    };
    const { common } = loadCommon(state);
    common.renameRefs("ruleset", "russia_inside", "ru_in");

    expect(state.rr.rule_set).toEqual(["ru_in", "discord"]);
    // A single-item UCI list arrives as a scalar; it must still be rewritten.
    expect(state.dr.rule_set).toEqual(["ru_in"]);
  });

  it("rewrites dns_server references held by the dns singleton", () => {
    const state: Record<string, UciSection> = {
      google: { ".name": "google", ".type": "dns_server" },
      dns: {
        ".name": "dns",
        ".type": "dns",
        final: "google",
        default_resolver: "google",
      },
    };
    const { common } = loadCommon(state);
    common.renameRefs("dns_server", "google", "goog");

    expect(state.dns.final).toBe("goog");
    expect(state.dns.default_resolver).toBe("goog");
  });

  it("rewrites the dns_server refs nothing validates", () => {
    // domain_resolver / address_resolver / route_rule.server are the ones the
    // backend does NOT check: a dangling tag ships straight into the config and
    // sing-box refuses the whole file, so the pre-flight cancels the reload and
    // Apply looks like it just did nothing.
    const state: Record<string, UciSection> = {
      boot: { ".name": "boot", ".type": "dns_server" },
      doh: {
        ".name": "doh",
        ".type": "dns_server",
        domain_resolver: "boot",
      },
      leg: {
        ".name": "leg",
        ".type": "dns_server",
        address_resolver: "boot",
      },
      rr: {
        ".name": "rr",
        ".type": "route_rule",
        action: "resolve",
        server: "boot",
      },
    };
    const { common } = loadCommon(state);
    common.renameRefs("dns_server", "boot", "bootstrap");

    expect(state.doh.domain_resolver).toBe("bootstrap");
    expect(state.leg.address_resolver).toBe("bootstrap");
    expect(state.rr.server).toBe("bootstrap");
  });

  it("rewrites the two outbound refs that live outside the protocol tabs", () => {
    // clash_api's external UI download detour, and the ONE shared detour every
    // built-in rule-set inherits. The latter degrades quietly: ruleset.uc drops
    // the dangling tag with a warn and all 25 built-ins stop downloading via
    // the proxy.
    const state: Record<string, UciSection> = {
      wan: { ".name": "wan", ".type": "outbound" },
      clash_api: {
        ".name": "clash_api",
        ".type": "clash_api",
        external_ui_download_detour: "wan",
      },
      main: {
        ".name": "main",
        ".type": "singbox-ui",
        default_ruleset_detour: "wan",
      },
    };
    const { common } = loadCommon(state);
    common.renameRefs("outbound", "wan", "uplink");

    expect(state.clash_api.external_ui_download_detour).toBe("uplink");
    expect(state.main.default_ruleset_detour).toBe("uplink");
  });

  it("rewrites an inbound's detour when the inbound it points at is renamed", () => {
    // The shared listen block gives every inbound a `detour` naming ANOTHER
    // inbound. sing-box does not catch a dangling one — `sing-box check` returns
    // 0 and the daemon starts, the detour simply never happens — so an inbound
    // rename that skips this ref fails silently.
    const state: Record<string, UciSection> = {
      other_in: { ".name": "other_in", ".type": "inbound", protocol: "mixed" },
      mx: {
        ".name": "mx",
        ".type": "inbound",
        protocol: "mixed",
        detour: "other_in",
      },
      keep: {
        ".name": "keep",
        ".type": "inbound",
        protocol: "socks",
        detour: "someone_else",
      },
    };
    const { common } = loadCommon(state);
    common.renameRefs("inbound", "other_in", "injectme");

    expect(state.mx.detour).toBe("injectme");
    expect(state.keep.detour).toBe("someone_else");
  });

  it("rewrites a tun inbound's route_address_set / route_exclude_address_set on a rule-set rename", () => {
    // Task 5 review F2: before Task 5, a stale tun reference made sing-box
    // refuse the config outright — loud. Task 5's prune (inbound.uc) turned
    // that into a SILENT full-tunnel (the reference just vanishes). This
    // table entry is what keeps a rule-set rename from creating one.
    const state: Record<string, UciSection> = {
      ru_block: { ".name": "ru_block", ".type": "ruleset" },
      ru_bypass: { ".name": "ru_bypass", ".type": "ruleset" },
      tun_in: {
        ".name": "tun_in",
        ".type": "inbound",
        protocol: "tun",
        route_address_set: ["ru_block", "other"],
        route_exclude_address_set: "ru_bypass",
      },
    };
    const { common } = loadCommon(state);
    common.renameRefs("ruleset", "ru_block", "ru_block2");
    common.renameRefs("ruleset", "ru_bypass", "ru_bypass2");

    expect(state.tun_in.route_address_set).toEqual(["ru_block2", "other"]);
    // A single-item UCI list arrives as a scalar; it must still be rewritten.
    expect(state.tun_in.route_exclude_address_set).toEqual(["ru_bypass2"]);
  });

  it("leaves unrelated kinds alone", () => {
    const state: Record<string, UciSection> = {
      rr: { ".name": "rr", ".type": "route_rule", outbound: "wan" },
    };
    const { common } = loadCommon(state);
    // Renaming a dns_server must not touch an outbound reference that happens
    // to carry the same name.
    common.renameRefs("dns_server", "wan", "lan");
    expect(state.rr.outbound).toBe("wan");
  });
});
