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

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

type Opt = Record<string, unknown>;

interface Section {
  sectiontype: string;
  option(widget: unknown, name: string): Opt;
  taboption(tab: string, widget: unknown, name: string): Opt;
}

interface UciSection {
  ".name": string;
  [k: string]: unknown;
}

function loadCommon(state: Record<string, UciSection>) {
  const uci = {
    get: (_cfg: string, sid: string, opt?: string) =>
      opt === undefined ? (state[sid] ?? null) : (state[sid]?.[opt] ?? null),
    set: (_cfg: string, sid: string, opt: string, val: unknown) => {
      state[sid] = state[sid] ?? { ".name": sid };
      state[sid][opt] = val;
    },
    rename: (_cfg: string, sid: string, to: string) => {
      const sec = state[sid];
      delete state[sid];
      sec[".name"] = to;
      state[to] = sec;
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

  it("write() rewrites referring sections, then renames", () => {
    const state: Record<string, UciSection> = {
      vless_out: { ".name": "vless_out", ".type": "outbound" },
      grp: {
        ".name": "grp",
        ".type": "outbound",
        group_outbounds: ["vless_out", "other_out"],
        group_default: "vless_out",
      },
      rr: { ".name": "rr", ".type": "route_rule", outbound: "vless_out" },
      rd: {
        ".name": "rd",
        ".type": "route_default",
        outbound: "vless_out",
      },
      untouched: {
        ".name": "untouched",
        ".type": "route_rule",
        outbound: "other_out",
      },
    };
    const { common } = loadCommon(state);
    const s = makeSection("outbound");
    common.addRenameField(s, "basic");
    const write = s.registered[0].opt.write as (sid: string, v: string) => void;

    write("vless_out", "tokyo");

    expect(state.tokyo).toBeDefined();
    expect(state.vless_out).toBeUndefined();
    expect(state.grp.group_outbounds).toEqual(["tokyo", "other_out"]);
    expect(state.grp.group_default).toBe("tokyo");
    expect(state.rr.outbound).toBe("tokyo");
    expect(state.rd.outbound).toBe("tokyo");
    expect(state.untouched.outbound).toBe("other_out");
  });

  it("write() is a no-op when the name is unchanged", () => {
    const state: Record<string, UciSection> = {
      rs: { ".name": "rs", ".type": "ruleset" },
      rr: { ".name": "rr", ".type": "route_rule", rule_set: ["rs"] },
    };
    const { common } = loadCommon(state);
    const s = makeSection("ruleset");
    common.addRenameField(s, "basic");
    const write = s.registered[0].opt.write as (sid: string, v: string) => void;

    write("rs", "rs");
    expect(state.rs).toBeDefined();
    expect(state.rr.rule_set).toEqual(["rs"]);
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
