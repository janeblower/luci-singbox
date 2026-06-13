// tests/parity/dns_corpus.uc — DNS server parity fixtures.
// Each fixture is {name, section} where section is a UCI-section-shaped dict
// (string values, ".name" key). The legacy-type fixtures (fakeip/udp/tls/https)
// only set fields that the legacy build_servers reads, so the golden == legacy
// output exactly. New-type fixtures (Step 6) have hand-verified goldens.
//
// Legacy build_servers reads per type:
//   fakeip  : inet4_range, inet6_range
//   udp/tls : server, server_port (1..65535 int), detour, domain_resolver
//   https   : server, server_port, path, detour, domain_resolver
//   other   : skipped with warn

return [
    // -----------------------------------------------------------------------
    // Legacy-type fixtures (goldens captured from pre-refactor build_servers)
    // -----------------------------------------------------------------------
    {
        name: "dns_udp_min",
        section: { [".name"]: "u1", enabled: "1", type: "udp",
                   server: "1.1.1.1", server_port: "53" },
    },
    {
        name: "dns_udp_resolver",
        section: { [".name"]: "u2", enabled: "1", type: "udp",
                   server: "dns.example", server_port: "53",
                   domain_resolver: "u1" },
    },
    {
        name: "dns_tls_detour",
        section: { [".name"]: "t1", enabled: "1", type: "tls",
                   server: "1.1.1.1", server_port: "853",
                   detour: "proxy", domain_resolver: "u1" },
    },
    {
        name: "dns_https_path",
        section: { [".name"]: "h1", enabled: "1", type: "https",
                   server: "dns.google", server_port: "443",
                   path: "/dns-query" },
    },
    {
        name: "dns_https_plain",
        section: { [".name"]: "h2", enabled: "1", type: "https",
                   server: "dns.google", server_port: "443" },
    },
    {
        name: "dns_fakeip",
        section: { [".name"]: "f1", enabled: "1", type: "fakeip",
                   inet4_range: "198.18.0.0/15", inet6_range: "fc00::/18" },
    },

    // -----------------------------------------------------------------------
    // New-type fixtures (Step 6 — hand-verified against sing-box docs)
    // -----------------------------------------------------------------------
    {
        name: "dns_tcp_min",
        section: { [".name"]: "tc1", enabled: "1", type: "tcp",
                   server: "1.1.1.1", server_port: "53" },
    },
    {
        name: "dns_quic_min",
        section: { [".name"]: "q1", enabled: "1", type: "quic",
                   server: "dns.adguard.com", server_port: "784" },
    },
    {
        name: "dns_h3_min",
        section: { [".name"]: "h3s", enabled: "1", type: "h3",
                   server: "dns.cloudflare.com", server_port: "443",
                   path: "/dns-query" },
    },
    {
        name: "dns_local",
        section: { [".name"]: "loc1", enabled: "1", type: "local" },
    },
    {
        name: "dns_hosts",
        section: { [".name"]: "hs1", enabled: "1", type: "hosts" },
    },
    {
        name: "dns_dhcp_iface",
        section: { [".name"]: "dh1", enabled: "1", type: "dhcp",
                   interface: "eth0" },
    },
    {
        name: "dns_mdns_iface",
        section: { [".name"]: "md1", enabled: "1", type: "mdns",
                   interface: [ "eth0", "eth1" ] },
    },
    {
        name: "dns_tailscale",
        section: { [".name"]: "ts1", enabled: "1", type: "tailscale",
                   endpoint: "ts-endpoint" },
    },
    {
        name: "dns_resolved",
        section: { [".name"]: "res1", enabled: "1", type: "resolved",
                   service: "systemd-resolved" },
    },
];
