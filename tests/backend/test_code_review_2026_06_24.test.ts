import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// Regression coverage for the second code-review batch (themes 1-4):
// disp-3 resolver type-gate, disp-4 clash_api warn, and the declarative gate
// projections (dns-3 required, cxc-1/prot-3 version gates, uic-8 alpn validate).
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

describe("code-review 2026-06-24 batch", () => {
  useGuest();

  async function generate(uci: string): Promise<Record<string, any>> {
    const dir = `/tmp/cr2_${process.pid}_${Math.floor(Math.random() * 1e6)}`;
    await exec(`mkdir -p ${dir}/subs`);
    await putFile(uci, `${dir}/singbox-ui`);
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/subs SINGBOX_CONFIG=${dir}/out.json ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; rc=$?; if [ $rc -eq 0 ]; then cat ${dir}/out.json; else echo GENFAIL; fi; rm -rf ${dir}`,
    );
    expect(r.stdout).not.toContain("GENFAIL");
    return JSON.parse(r.stdout);
  }

  it("disp-3: resolver auto-pick skips non-resolver dns types (hosts) for a resolving one", async () => {
    const uci =
      "config dns_server 'myhosts'\n\toption enabled '1'\n\toption type 'hosts'\n\n" +
      "config dns_server 'myudp'\n\toption enabled '1'\n\toption type 'udp'\n\toption server '8.8.8.8'\n\n" +
      "config dns 'dns'\n";
    const cfg = await generate(uci);
    expect(cfg.route?.default_domain_resolver?.server).toBe("myudp");
  });

  it("disp-3: no resolver-capable server → no default_domain_resolver", async () => {
    const uci =
      "config dns_server 'myhosts'\n\toption enabled '1'\n\toption type 'hosts'\n\n" +
      "config dns 'dns'\n";
    const cfg = await generate(uci);
    expect(cfg.route?.default_domain_resolver).toBeUndefined();
  });

  it("disp-4: clash_api on non-loopback with empty secret warns (warn-only)", async () => {
    const r = await runUcode(`
let clash = require("clash");
let CFG = { clash_api: { [".name"]: "clash_api", enabled: "1", listen: "0.0.0.0", port: "9090" } };
let cur = { get_all: function(_p, t) { return CFG[t]; } };
let out = clash.build_clash_api(cur);
print(out.external_controller); print("\\n");
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("0.0.0.0:9090");
    expect(r.stderr).toContain("UNAUTHENTICATED");
  });

  it("disp-4: loopback OR a present secret → no warning", async () => {
    const loop = await runUcode(`
let clash = require("clash");
let CFG = { clash_api: { [".name"]: "clash_api", enabled: "1", listen: "127.0.0.1", port: "9090" } };
clash.build_clash_api({ get_all: function(_p, t) { return CFG[t]; } });
print("done\\n");
`);
    expect(loop.exitCode).toBe(0);
    expect(loop.stderr).not.toContain("UNAUTHENTICATED");

    const withSecret = await runUcode(`
let clash = require("clash");
let CFG = { clash_api: { [".name"]: "clash_api", enabled: "1", listen: "0.0.0.0", port: "9090", secret: "tok" } };
clash.build_clash_api({ get_all: function(_p, t) { return CFG[t]; } });
print("done\\n");
`);
    expect(withSecret.exitCode).toBe(0);
    expect(withSecret.stderr).not.toContain("UNAUTHENTICATED");
  });

  it("schema gates: dns-3 required, cxc-1/prot-3 version, uic-8 alpn validate are projected", async () => {
    const out = await runUcodeJSON<Record<string, unknown>>(`
require("outbound"); require("inbound");
let dump = require("builder.protocols.schema_dump").dump_all();
function findf(fields, name) { for (let f in fields) if (f.name == name) return f; return null; }
let server = findf(dump.dns_rule.default.fields, "server");
let rw  = findf(dump.outbound.hysteria.fields, "recv_window");
let rwc = findf(dump.outbound.hysteria.fields, "recv_window_conn");
let alpn = findf(dump.outbound.vless.fields, "tls_alpn");
print(sprintf("%J", {
  dns3_required:       server ? server.required : null,
  cxc1_tailscale_minv: dump.dns.tailscale.min_version,
  prot3_rw_maxv:       rw  ? rw.max_version  : null,
  prot3_rwc_maxv:      rwc ? rwc.max_version : null,
  alpn_validate:       alpn ? alpn.validate : null,
}));
`);
    expect(out.dns3_required).toBe(true);
    expect(out.cxc1_tailscale_minv).toBe("1.14");
    expect(out.prot3_rw_maxv).toBe("1.14");
    expect(out.prot3_rwc_maxv).toBe("1.14");
    expect(out.alpn_validate).toBe("validateAlpn");
  });
});
