// lib/builder/dns/registry.uc — eager-loads every DNS server descriptor so its
// register() fires, then re-exports the shared protocol registry surface.
let reg = require("builder.protocols.registry");

let _modules = [
    "builder.dns.udp", "builder.dns.tcp", "builder.dns.tls", "builder.dns.quic",
    "builder.dns.https", "builder.dns.h3", "builder.dns.fakeip", "builder.dns.local",
    "builder.dns.hosts", "builder.dns.dhcp", "builder.dns.mdns", "builder.dns.tailscale",
    "builder.dns.resolved", "builder.dns.legacy",
];
for (let m in _modules) {
    try { require(m); }
    catch (e) { warn(sprintf("dns/registry: failed to load %s: %s\n", m, e)); }
}

return reg;
