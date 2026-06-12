// lib/protocols/_shared/multiplex.uc

let helpers = require("helpers");
const s_opt  = helpers.s_opt;
const s_bool = helpers.s_bool;
const s_num  = helpers.s_num;

function emit(s) {
    if (!s_bool(s, "multiplex_enabled")) return null;
    let m = {
        enabled: true,
        protocol: length(s_opt(s, "multiplex_protocol")) ? s.multiplex_protocol : "smux",
    };
    if (length(s_opt(s, "multiplex_max_connections")))
        m.max_connections = s_num(s.multiplex_max_connections);
    if (length(s_opt(s, "multiplex_min_streams")))
        m.min_streams = s_num(s.multiplex_min_streams);
    if (length(s_opt(s, "multiplex_max_streams")))
        m.max_streams = s_num(s.multiplex_max_streams);
    if (s_bool(s, "multiplex_padding")) m.padding = true;
    return m;
}

return {
    applies_to: { kinds: [ "inbound", "outbound" ] },

    fields: [
        { name: "multiplex_enabled", type: "bool", tab: "multiplex",
          ui_label: "Enable multiplex", default: 0 },
        { name: "multiplex_protocol", type: "enum", tab: "multiplex",
          ui_label: "Multiplex protocol",
          values: ["smux", "yamux", "h2mux"], default: "smux",
          parent_enabled: "multiplex_enabled" },

        { name: "multiplex_max_connections", type: "number", tab: "multiplex",
          ui_label: "Max connections", default: 4,
          parent_enabled: "multiplex_enabled", advanced: true },
        { name: "multiplex_min_streams", type: "number", tab: "multiplex",
          ui_label: "Min streams",
          parent_enabled: "multiplex_enabled", advanced: true },
        { name: "multiplex_max_streams", type: "number", tab: "multiplex",
          ui_label: "Max streams",
          parent_enabled: "multiplex_enabled", advanced: true },
        { name: "multiplex_padding", type: "bool", tab: "multiplex",
          ui_label: "Padding", default: 0,
          parent_enabled: "multiplex_enabled", advanced: true },
    ],

    emit: emit,

    emit_spec: {
        gate: { enabled_field: "multiplex_enabled" },
        seq: [
            { json_key: "enabled", const: true },
            { name: "multiplex_protocol", json_key: "protocol", default_when_empty: "smux", omit_when: "never" },
            { name: "multiplex_max_connections", json_key: "max_connections", coerce: "num" },
            { name: "multiplex_min_streams",     json_key: "min_streams", coerce: "num" },
            { name: "multiplex_max_streams",     json_key: "max_streams", coerce: "num" },
            { name: "multiplex_padding",         json_key: "padding", coerce: "bool" },
        ],
    },
};
