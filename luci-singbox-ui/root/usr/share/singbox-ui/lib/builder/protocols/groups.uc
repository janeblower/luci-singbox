// lib/builder/protocols/groups.uc — selector + urltest group outbounds (E2 DSL).
// `outbounds` is a free-entry list of outbound tags (dynamic:outbounds, multi).
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "selector", sing_box_type: "selector",
    fields: [
        { name: "group_outbounds", type: "list", tab: "basic", dynamic: "outbounds",
          ui_label: "Member outbounds", json_key: "outbounds", coerce: "array", omit_when: "never" },
        { name: "group_default", type: "string", tab: "basic", dynamic: "outbounds",
          ui_label: "Default outbound", json_key: "default" },
        { name: "interrupt_exist_connections", type: "bool", tab: "basic",
          ui_label: "Interrupt existing connections", default: 0,
          json_key: "interrupt_exist_connections", coerce: "bool" },
    ],
});

reg.register({
    kind: "outbound", type: "urltest", sing_box_type: "urltest",
    fields: [
        { name: "group_outbounds", type: "list", tab: "basic", dynamic: "outbounds",
          ui_label: "Member outbounds", json_key: "outbounds", coerce: "array", omit_when: "never" },
        { name: "group_url", type: "string", tab: "basic", ui_label: "Test URL",
          placeholder: "https://www.gstatic.com/generate_204", json_key: "url" },
        { name: "group_interval", type: "string", tab: "basic", ui_label: "Interval",
          placeholder: "3m", advanced: true, json_key: "interval" },
        { name: "group_tolerance", type: "number", tab: "basic", ui_label: "Tolerance (ms)",
          advanced: true, json_key: "tolerance", coerce: "num" },
        { name: "group_idle_timeout", type: "string", tab: "basic", ui_label: "Idle timeout",
          placeholder: "30m", advanced: true, json_key: "idle_timeout" },
        { name: "interrupt_exist_connections", type: "bool", tab: "basic",
          ui_label: "Interrupt existing connections", default: 0,
          json_key: "interrupt_exist_connections", coerce: "bool" },
    ],
});

return {};
