// tests/parity/settings_corpus.uc — cache + clash_api singleton parity fixtures.
// {name, kind, type, section}. Cache fixtures are added by a later task.
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
];
