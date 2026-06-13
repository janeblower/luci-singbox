#!/bin/sh
# tests/test_dns_parity.sh — semantic parity: the new build_servers dispatcher
# must produce canon-identical JSON to the pre-refactor legacy build_servers for
# every corpus fixture that has a golden (fakeip/udp/tls/https + new types).
# Mirror of tests/test_protocol_parity.sh, but for DNS server descriptors.
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_dns_parity (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L tests/parity -L "$LIB" -e '
    let uci_mod = require("uci");
    let fs      = require("fs");
    let canon   = require("canon").canon;
    let corpus  = require("dns_corpus");
    let dns     = require("dns");
    let fails   = 0;

    // Write a temp UCI config dir for a single dns_server section.
    function write_uci_config(section) {
        let name    = section[".name"];
        let tmp_dir = sprintf("/tmp/dns_par_%s", name);
        fs.mkdir(tmp_dir);
        let lines = [ sprintf("config dns_server '"'"'%s'"'"'", name) ];
        for (let k in keys(section)) {
            if (k === ".name") continue;
            let v = section[k];
            if (type(v) === "array") {
                for (let item in v)
                    push(lines, sprintf("\tlist %s '"'"'%s'"'"'", k, item));
            } else {
                push(lines, sprintf("\toption %s '"'"'%s'"'"'", k, v));
            }
        }
        let f = fs.open(sprintf("%s/singbox-ui", tmp_dir), "w");
        f.write(join("\n", lines) + "\n");
        f.close();
        return tmp_dir;
    }

    for (let fx in corpus) {
        let golden_path = sprintf("tests/parity/golden/%s.json", fx.name);
        let want_f = fs.open(golden_path, "r");
        if (want_f == null) {
            // New-type fixtures without a golden yet — skip until Step 6.
            print(sprintf("SKIP (no golden yet): %s\n", fx.name));
            continue;
        }
        let want = trim(want_f.read("all")); want_f.close();

        let tmp_dir = write_uci_config(fx.section);
        let cur     = uci_mod.cursor(tmp_dir);
        let out     = dns.build_dns(cur);
        let srv = (out != null && type(out.servers) === "array" && length(out.servers) > 0)
                  ? out.servers[0] : null;
        if (srv == null) {
            print(sprintf("MISSING output for %s\n", fx.name));
            fails++;
            continue;
        }
        let g = sprintf("%J", canon(srv));
        if (g !== want) {
            print(sprintf("DRIFT %s\n  got =%s\n  want=%s\n", fx.name, g, want));
            fails++;
        }
    }
    print(fails === 0 ? "ALLOK\n" : sprintf("FAILS=%d\n", fails));
')
echo "$out"
echo "$out" | grep -q '^ALLOK$' || { echo "FAIL: dns parity drift"; exit 1; }
echo "test_dns_parity: all PASS"
