// lib/builder/protocols/redirect.uc — Redirect inbound (Linux/macOS REDIRECT target).
let reg = require("builder.protocols.registry");

reg.register({
    kind: "inbound", type: "redirect", sing_box_type: "redirect",
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 7894, ui_label: "Listen port" },
    ],
});

return {};
