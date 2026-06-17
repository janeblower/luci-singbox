// lib/builder/settings/cache.uc — sing-box experimental.cache_file (singleton).
// `storage`/`path` are UI-only (no json_key); cache.uc's dispatcher computes the
// resolved JSON `path` and applies the fakeip cross-gate. store_rdrc/rdrc_timeout
// are sing-box 1.9 (below the 1.12 floor → ungated). Everything else is direct
// json_key. `enabled` HAS json_key — unlike clash_api, cache_file uses it.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "cache", type: "cache", sing_box_type: "cache_file",
    fields: [
        { name: "enabled", type: "bool", tab: "basic", json_key: "enabled",
          coerce: "bool", required: true, ui_label: "Enable cache file" },
        { name: "storage", type: "enum", tab: "basic",
          values: [ "ram", "flash", "custom" ], default: "ram",
          parent_enabled: "enabled", ui_label: "Storage" },
        { name: "path", type: "string", tab: "basic",
          parent_enabled: "enabled", depends: { field: "storage", value: "custom" },
          placeholder: "/srv/singbox-cache.db", ui_label: "Custom path" },
        { name: "store_fakeip", type: "bool", tab: "basic", json_key: "store_fakeip",
          coerce: "bool", required: true, parent_enabled: "enabled",
          ui_label: "Persist fakeip mappings",
          ui_help: "Effective only when a DNS server of type fakeip is enabled." },
        { name: "store_rdrc", type: "bool", tab: "basic", advanced: true,
          json_key: "store_rdrc", coerce: "bool", parent_enabled: "enabled",
          ui_label: "Store rejected-domain cache" },
        { name: "rdrc_timeout", type: "string", tab: "basic", advanced: true,
          json_key: "rdrc_timeout", parent_enabled: "enabled",
          ui_label: "RDRC timeout" },
        { name: "cache_id", type: "string", tab: "basic", advanced: true,
          json_key: "cache_id", parent_enabled: "enabled",
          ui_label: "Cache ID" },
    ],
});
return {};
