// lib/protocols/tproxy.uc — TProxy inbound under the E2 DSL.

let reg = require("builder.protocols.registry");

reg.register({
    kind: "inbound", type: "tproxy", sing_box_type: "tproxy",
    shared: { listen: true },

    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::",
          ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 7895, ui_label: "Listen port" },
        { name: "network", type: "enum", tab: "basic",
          values: ["", "tcp", "udp"], default: "",
          ui_label: "Network", json_key: "network", only_values: ["tcp", "udp"] },
        // UI-only (no json_key) — persisted to UCI, consumed by nftables.uc,
        // NOT emitted to sing-box JSON. Must NOT be `virtual`:
        // descriptor_form.makeVirtual() write-suppresses virtual fields, which
        // silently discarded every modal edit. The interface set holds netdev
        // DEVICE names (br-lan, eth0, eth0.100) — nftables matches via iifname.
        { name: "interface", type: "list", tab: "basic",
          ui_label: "Interfaces to redirect (nftables)", dynamic: "devices" },
        { name: "nft_rules", type: "bool", tab: "basic",
          ui_label: "Install nftables redirect rules", default: 1,
          // Exclusive group "transparent" = system routing / the firewall, which
          // has exactly ONE owner. This flag claims it with our own `inet
          // singbox_ui` table + an ip rule; tun.auto_route claims the same thing
          // by other means (sing-box's own policy routing). descriptor_form
          // disables the loser's checkbox and names the owner; generate.uc
          // refuses to build (rc 3) if UCI is edited behind the UI's back.
          //
          // The group SUPERSEDES the old `exclusive: true`: makeExclusive scans
          // every enabled inbound and asks that protocol's claim field, so a
          // second tproxy inbound still claims via nft_rules and is still barred
          // (one mark, one ip rule) — the same-protocol guarantee is a subset of
          // the group's. Polarity: default 1 + no json_key ⇒ UNSET MEANS ON.
          exclusive: "transparent" },
        { name: "fwmark", type: "string", tab: "basic",
          ui_label: "Firewall mark (fwmark)", default: "0x40000000",
          // UI/UCI-only (no json_key) — consumed by nftables.uc. Shown only
          // when this inbound owns the nft rules. Backend safe_fwmark validates
          // and falls back to the default on a malformed value.
          ui_help: "Overrides the global mark for this inbound. The matching `ip rule` (policy route to the proxy table) must use THIS value.",
          depends: { field: "nft_rules", value: "1" } },
        { name: "hijack_dns", type: "bool", tab: "basic",
          ui_label: "Hijack DNS via nftables", default: 0 },
    ],
});

return {};
