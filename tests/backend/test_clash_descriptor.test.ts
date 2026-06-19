import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

describe("test_clash_descriptor", () => {
  useGuest();

  it("clash_api descriptor is registered and filler builds correct output", async () => {
    const src = `
require("builder.settings.registry");
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
let d = reg.get("clash_api", "clash_api");
if (d == null) { print("FAIL: not registered\\n"); exit(1); }
let s = { [".name"]: "clash_api", enabled: "1", listen: "::1", port: "9090",
          secret: "tok", external_ui: "/www/ui", default_mode: "rule",
          access_control_allow_private_network: "1" };
let out = filler.build(d, s);
if (out.external_controller != "[::1]:9090") { print(sprintf("FAIL ec=%s\\n", out.external_controller)); exit(1); }
if (out.secret != "tok") { print("FAIL secret\\n"); exit(1); }
if (out.external_ui != "/www/ui") { print("FAIL external_ui\\n"); exit(1); }
if (out.default_mode != "rule") { print("FAIL default_mode\\n"); exit(1); }
if (out.access_control_allow_private_network != true) { print("FAIL acapn\\n"); exit(1); }
if ("enabled" in out) { print("FAIL: enabled leaked to JSON\\n"); exit(1); }
if ("listen" in out || "port" in out) { print("FAIL: listen/port leaked to JSON\\n"); exit(1); }
let out2 = filler.build(d, { [".name"]: "clash_api", enabled: "1", listen: "127.0.0.1", port: "9090" });
if (out2.external_controller != "127.0.0.1:9090") { print(sprintf("FAIL ec4=%s\\n", out2.external_controller)); exit(1); }
let out3 = filler.build(d, { [".name"]: "clash_api", enabled: "1", listen: "[::1]", port: "9090" });
if (out3.external_controller != "[::1]:9090") { print(sprintf("FAIL ec_bracketed=%s\\n", out3.external_controller)); exit(1); }
print("OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("clash.uc build_clash_api bracketing via uci cursor", async () => {
    const src = `
let uci = require("uci");
let clash = require("clash");
let fs = require("fs");

let cfgDir = "/tmp/clash_desc_${process.pid}";
fs.mkdir(cfgDir);

function run(listen, port) {
  fs.writefile(cfgDir + "/singbox-ui",
    "config clash_api 'clash_api'\\n    option enabled '1'\\n    option listen '" + listen + "'\\n    option port '" + port + "'\\n");
  let cur = uci.cursor(cfgDir);
  let out = clash.build_clash_api(cur);
  return out.external_controller;
}

let r;
r = run("127.0.0.1", "9090");
if (r != "127.0.0.1:9090") { print("FAIL ipv4: " + r + "\\n"); exit(1); }
r = run("::1", "9090");
if (r != "[::1]:9090") { print("FAIL ipv6: " + r + "\\n"); exit(1); }
r = run("::", "9090");
if (r != "[::]:9090") { print("FAIL ipv6 any: " + r + "\\n"); exit(1); }

system("rm -rf " + cfgDir);
print("OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
