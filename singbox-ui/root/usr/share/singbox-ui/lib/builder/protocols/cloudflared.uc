// lib/builder/protocols/cloudflared.uc — Cloudflare Tunnel inbound (Since 1.14.0).
// No listen fields -> hand emit() (escape-hatch). control_dialer/tunnel_dialer
// (nested dial objects) are out of scope.
let reg = require("builder.protocols.registry");
let helpers = require("helpers");
const s_opt = helpers.s_opt;
const s_num = helpers.s_num;
const s_bool = helpers.s_bool;

function emit_cloudflared(s) {
    let token = s_opt(s, "token");
    if (!length(token)) {
        warn(sprintf("cloudflared inbound: missing token for '%s'\n", s[".name"]));
        return null;
    }
    let out = { type: "cloudflared", tag: s[".name"], token: token };
    if (length(s_opt(s, "ha_connections"))) out.ha_connections = s_num(s.ha_connections);
    if (length(s_opt(s, "cf_protocol")))    out.protocol = s.cf_protocol;
    if (s_bool(s, "post_quantum"))          out.post_quantum = true;
    if (length(s_opt(s, "edge_ip_version"))) out.edge_ip_version = s_num(s.edge_ip_version);
    if (length(s_opt(s, "datagram_version"))) out.datagram_version = s.datagram_version;
    if (length(s_opt(s, "grace_period")))   out.grace_period = s.grace_period;
    if (length(s_opt(s, "region")))         out.region = s.region;
    return out;
}

reg.register({
    kind: "inbound", type: "cloudflared", sing_box_type: "cloudflared",
    min_version: "1.14",
    fields: [
        { name: "token", type: "string", tab: "basic", required: true, secret: true,
          ui_label: "Tunnel token" },
        { name: "ha_connections", type: "number", tab: "basic",
          ui_label: "HA connections", advanced: true },
        { name: "cf_protocol", type: "enum", tab: "basic", values: ["", "http2", "quic"],
          ui_label: "Protocol", advanced: true },
        { name: "post_quantum", type: "bool", tab: "basic", ui_label: "Post-quantum",
          default: 0, advanced: true },
        { name: "edge_ip_version", type: "enum", tab: "basic", values: ["", "4", "6"],
          ui_label: "Edge IP version", advanced: true },
        { name: "datagram_version", type: "string", tab: "basic",
          ui_label: "Datagram version", advanced: true },
        { name: "grace_period", type: "string", tab: "basic",
          ui_label: "Grace period", placeholder: "30s", advanced: true },
        { name: "region", type: "string", tab: "basic", ui_label: "Region", advanced: true },
    ],
    emit: emit_cloudflared,
});

return {};
