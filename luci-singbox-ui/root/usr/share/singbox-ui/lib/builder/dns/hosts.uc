// lib/builder/dns/hosts.uc — hosts-file DNS server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "hosts", sing_box_type: "hosts",
    fields: [
        { name: "path", type: "list", tab: "basic", placeholder: "/etc/hosts",
          ui_label: "Hosts file paths", json_key: "path", coerce: "array" },
    ],
});

return {};
