// lib/protocols/_shared/transport.uc

let helpers = require("helpers");
const s_opt   = helpers.s_opt;
const as_array = helpers.as_array;

function emit(s) {
    let t = s_opt(s, "transport_type") || "none";
    if (t === "none") return null;
    let tr = { type: t };
    if (t === "ws") {
        if (length(s_opt(s, "transport_path"))) tr.path = s.transport_path;
        if (length(s_opt(s, "transport_host"))) tr.headers = { Host: s.transport_host };
    } else if (t === "httpupgrade") {
        if (length(s_opt(s, "transport_path"))) tr.path = s.transport_path;
        if (length(s_opt(s, "transport_host_httpupgrade")))
            tr.host = s.transport_host_httpupgrade;
    } else if (t === "grpc") {
        if (length(s_opt(s, "transport_service_name")))
            tr.service_name = s.transport_service_name;
    } else if (t === "xhttp") {
        if (length(s_opt(s, "transport_path"))) tr.path = s.transport_path;
        if (length(s_opt(s, "transport_xhttp_mode"))) tr.mode = s.transport_xhttp_mode;
    } else if (t === "http") {
        let hosts = as_array(s.transport_hosts);
        if (length(hosts)) tr.host = hosts;
        if (length(s_opt(s, "transport_path"))) tr.path = s.transport_path;
    }
    return tr;
}

return {
    applies_to: { kinds: [ "inbound", "outbound" ] },

    fields: [
        { name: "transport_type", type: "enum", tab: "transport",
          ui_label: "Transport",
          values: ["none", "ws", "grpc", "httpupgrade", "xhttp", "http"],
          default: "none" },

        // ws / httpupgrade / xhttp / http (path doesn't apply to grpc / none)
        { name: "transport_path", type: "string", tab: "transport",
          ui_label: "Path", placeholder: "/",
          depends: { field: "transport_type", value: ["ws", "httpupgrade", "xhttp", "http"] } },

        // ws
        { name: "transport_host", type: "string", tab: "transport",
          ui_label: "Host header", placeholder: "example.com",
          depends: { field: "transport_type", value: "ws" } },

        // httpupgrade — single host
        { name: "transport_host_httpupgrade", type: "string", tab: "transport",
          ui_label: "Host", placeholder: "example.com",
          depends: { field: "transport_type", value: "httpupgrade" } },

        // grpc
        { name: "transport_service_name", type: "string", tab: "transport",
          ui_label: "gRPC service name", placeholder: "TunService",
          depends: { field: "transport_type", value: "grpc" } },

        // xhttp
        { name: "transport_xhttp_mode", type: "enum", tab: "transport",
          ui_label: "XHTTP mode",
          values: ["auto", "packet-up", "stream-up", "stream-one"],
          default: "auto",
          depends: { field: "transport_type", value: "xhttp" } },

        // http — list of hosts
        { name: "transport_hosts", type: "list", tab: "transport",
          ui_label: "Hosts",
          depends: { field: "transport_type", value: "http" } },

        // Advanced (rarely needed but documented)
        { name: "transport_max_early_data", type: "number", tab: "transport",
          ui_label: "Max early data (ws)", advanced: true,
          depends: { field: "transport_type", value: "ws" } },
        { name: "transport_early_data_header_name", type: "string", tab: "transport",
          ui_label: "Early-data header name (ws)", advanced: true,
          depends: { field: "transport_type", value: "ws" } },
    ],

    emit: emit,

    emit_spec: {
        variant: {
            selector: "transport_type",
            none_value: "none",
            emit_selector_as: "type",
            variants: {
                ws: [
                    { name: "transport_path", json_key: "path" },
                    { json_key: "headers", gate: { any_present: ["transport_host"] },
                      fields: [ { name: "transport_host", json_key: "Host" } ] },
                ],
                httpupgrade: [
                    { name: "transport_path", json_key: "path" },
                    { name: "transport_host_httpupgrade", json_key: "host" },
                ],
                grpc: [
                    { name: "transport_service_name", json_key: "service_name" },
                ],
                xhttp: [
                    { name: "transport_path", json_key: "path" },
                    { name: "transport_xhttp_mode", json_key: "mode" },
                ],
                http: [
                    { name: "transport_hosts", json_key: "host", coerce: "array" },
                    { name: "transport_path", json_key: "path" },
                ],
            },
        },
    },
};
