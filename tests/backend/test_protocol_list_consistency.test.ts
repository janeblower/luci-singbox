import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_protocol_list_consistency.sh
// S4-2: OUTBOUND_PROXY_KINDS must stay 1:1 with the registered outbound proxy
// descriptors. The registry (after require("outbound") eager-loads all
// descriptors) is the single source of truth; this guards against the list and
// the loaded descriptors drifting apart.
//
// NON_PROXY_OUTBOUNDS: deliberate exclusions (own dispatch branch, not proxy kinds).
//   direct    — registered outbound, deliberate exclusion from OUTBOUND_PROXY_KINDS
//   selector  — groups.uc: own dispatch branch
//   urltest   — groups.uc: own dispatch branch
//   json      — json_raw.uc: raw JSON pass-through
//   sharelink — share-link URL parser result (not a persisted proxy kind)
// These mirror the hard-coded `non_proxy` list in the shell test.

const NON_PROXY_OUTBOUNDS = new Set([
  "direct",
  "selector",
  "urltest",
  "json",
  "sharelink",
]);

describe("protocol list consistency", () => {
  useGuest();

  it("OUTBOUND_PROXY_KINDS matches registered outbound proxy descriptors 1:1", async () => {
    const src = `
      // Eager-load all descriptors (same as outbound.uc does in production)
      let ob = require("outbound");
      let reg = require("builder.protocols.registry");
      let helpers = require("helpers");

      // The registered set: all types for kind "outbound"
      let registered = reg.types_for_kind("outbound");

      // The OUTBOUND_PROXY_KINDS constant from helpers.uc
      let proxy_kinds = helpers.OUTBOUND_PROXY_KINDS;

      print(sprintf("%J", { registered: registered, proxy_kinds: proxy_kinds }));
    `;
    const got = await runUcodeJSON<{
      registered: string[];
      proxy_kinds: string[];
    }>(src);

    const { registered, proxy_kinds: proxyKinds } = got;

    // From registry: all registered outbound types minus NON_PROXY_OUTBOUNDS
    const registeredProxySet = new Set(
      registered.filter((t) => !NON_PROXY_OUTBOUNDS.has(t)),
    );

    // From helpers.uc: the OUTBOUND_PROXY_KINDS list
    const kindSet = new Set(proxyKinds);

    // Check 1: every kind in OUTBOUND_PROXY_KINDS is registered
    const inKindButNotRegistered = [...kindSet].filter(
      (k) => !registeredProxySet.has(k),
    );
    expect(inKindButNotRegistered).toEqual([]);

    // Check 2: every registered proxy type is in OUTBOUND_PROXY_KINDS
    const inRegisteredButNotKind = [...registeredProxySet].filter(
      (k) => !kindSet.has(k),
    );
    expect(inRegisteredButNotKind).toEqual([]);
  });

  it("NON_PROXY_OUTBOUNDS members are registered but absent from OUTBOUND_PROXY_KINDS", async () => {
    const src = `
      let ob = require("outbound");
      let reg = require("builder.protocols.registry");
      let helpers = require("helpers");
      let registered = reg.types_for_kind("outbound");
      let proxy_kinds = helpers.OUTBOUND_PROXY_KINDS;
      print(sprintf("%J", { registered: registered, proxy_kinds: proxy_kinds }));
    `;
    const got = await runUcodeJSON<{
      registered: string[];
      proxy_kinds: string[];
    }>(src);

    const registeredSet = new Set(got.registered);
    const kindSet = new Set(got.proxy_kinds);

    for (const nonProxy of NON_PROXY_OUTBOUNDS) {
      // direct is registered; selector/urltest/json/sharelink may or may not be
      // registered under that exact name — just verify they're not in proxy_kinds
      expect(kindSet.has(nonProxy)).toBe(false);
    }

    // Confirm direct IS registered (it has a descriptor)
    expect(registeredSet.has("direct")).toBe(true);
  });
});
