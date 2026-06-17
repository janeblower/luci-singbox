// tests/parity/settings_corpus.uc — cache + clash_api singleton parity fixtures.
// {name, kind, type, section}.
return [
    { name: "clash_min", kind: "clash_api", type: "clash_api",
      section: { [".name"]: "clash_api", enabled: "1", listen: "127.0.0.1", port: "9090" } },
    { name: "clash_full", kind: "clash_api", type: "clash_api",
      section: { [".name"]: "clash_api", enabled: "1", listen: "::1", port: "9090",
                 secret: "tok", external_ui: "/www/ui",
                 external_ui_download_url: "https://x/ui.zip",
                 external_ui_download_detour: "direct", default_mode: "rule",
                 access_control_allow_origin: [ "*" ],
                 access_control_allow_private_network: "1" } },
    { name: "cache_ram", kind: "cache", type: "cache",
      section: { [".name"]: "cache", enabled: "1", storage: "ram", store_fakeip: "1" } },
    { name: "cache_full", kind: "cache", type: "cache",
      section: { [".name"]: "cache", enabled: "1", storage: "custom", path: "/x.db",
                 store_fakeip: "1", store_rdrc: "1", rdrc_timeout: "5m", cache_id: "id" } },
];
