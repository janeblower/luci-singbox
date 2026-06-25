import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

describe("warp register/parse", () => {
  useGuest();

  it("register_auto parses a mocked CF /reg response", async () => {
    const r = await exec(`
      set -e
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      cat > /tmp/m_awg <<'EOF'
#!/bin/sh
case "$1" in genkey) echo "aGVsbG8td2cta2V5LXByaXZhdGUtMzJieXRlcw==";; pubkey) echo "cHViLWtleS0zMmJ5dGVzLWJhc2U2NC1lbmNvZGVk";; esac
EOF
      cat > /tmp/m_curl <<'EOF'
#!/bin/sh
cat <<'JSON'
{"config":{"client_id":"I0q+","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:8530::2"}},"peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=","endpoint":{"host":"engage.cloudflareclient.com:2408"}}]}}
JSON
EOF
      chmod +x /tmp/m_awg /tmp/m_curl
      AWG_BIN=/tmp/m_awg CURL=/tmp/m_curl ucode -L '${LIB}' -e '
        let w = require("plugins.awg_warp.warp");
        let res = w.register_auto();
        print(sprintf("%J", res));
      '
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.ok).toBe(true);
    expect(o.creds.peer_public_key).toBe(
      "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
    );
    expect(o.creds.address_v4).toContain("172.16.0.2");
    expect(o.creds.client_id).toBe("I0q+");
  });

  it("parse_conf extracts creds from a pasted .conf", async () => {
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      ucode -L '${LIB}' -e '
        let w = require("plugins.awg_warp.warp");
        let txt = "[Interface]\\nPrivateKey = ABCprivkeybase64==\\nAddress = 172.16.0.2/32, 2606:4700::2/128\\n[Peer]\\nPublicKey = PEERpub==\\nEndpoint = engage.cloudflareclient.com:2408\\n";
        print(sprintf("%J", w.parse_conf(txt)));
      '
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.ok).toBe(true);
    expect(o.creds.private_key).toBe("ABCprivkeybase64==");
    expect(o.creds.endpoint).toContain("engage.cloudflareclient.com:2408");
  });
});
