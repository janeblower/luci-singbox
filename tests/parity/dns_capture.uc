// tests/parity/dns_capture.uc — capture goldens from the CURRENT (legacy)
// build_servers via build_dns(cur).servers[0].
// Run BEFORE refactoring dns.uc:
//   ucode -L tests/parity -L luci-singbox-ui/root/usr/share/singbox-ui/lib \
//         tests/parity/dns_capture.uc
let uci_mod = require("uci");
let fs      = require("fs");
let canon   = require("canon").canon;
let corpus  = require("dns_corpus");
let dns     = require("dns");

let golden_dir = "tests/parity/golden";
fs.mkdir(golden_dir);

// Write a minimal UCI config for a single dns_server section into a temp dir.
function write_uci_config(section) {
    let name    = section[".name"];
    let tmp_dir = sprintf("/tmp/dns_cap_%s", name);
    fs.mkdir(tmp_dir);
    let lines = [ sprintf("config dns_server '%s'", name) ];
    for (let k in keys(section)) {
        if (k === ".name") continue;
        let v = section[k];
        if (type(v) === "array") {
            for (let item in v)
                push(lines, sprintf("\tlist %s '%s'", k, item));
        } else {
            push(lines, sprintf("\toption %s '%s'", k, v));
        }
    }
    let f = fs.open(sprintf("%s/singbox-ui", tmp_dir), "w");
    f.write(join("\n", lines) + "\n");
    f.close();
    return tmp_dir;
}

for (let fx in corpus) {
    let tmp_dir = write_uci_config(fx.section);
    let cur     = uci_mod.cursor(tmp_dir);
    let out     = dns.build_dns(cur);
    // build_dns returns {servers:[...], ...} or null.
    // For new types that build_servers doesn't know, it returns no servers.
    let srv = (out != null && type(out.servers) === "array" && length(out.servers) > 0)
              ? out.servers[0] : null;
    if (srv == null) {
        print(sprintf("SKIP (no legacy output): %s\n", fx.name));
        continue;
    }
    let path = sprintf("%s/%s.json", golden_dir, fx.name);
    let f2   = fs.open(path, "w");
    f2.write(sprintf("%J\n", canon(srv)));
    f2.close();
    print(sprintf("wrote golden: %s\n", fx.name));
}
print("dns_capture: done\n");
