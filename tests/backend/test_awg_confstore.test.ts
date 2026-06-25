// tests/backend/test_awg_confstore.test.ts
import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";

describe("awg confstore: ensure (register-or-reuse)", () => {
  useGuest();

  // Общий пролог: ставит mock awg/curl (register_auto) и mkdir-ит staging.
  const PRELUDE = `
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true
      cat > /tmp/m_awg <<'EOF'
#!/bin/sh
case "$1" in genkey) echo "cHJpdmF0ZS1rZXktMzJieXRlcy1iYXNlNjQtZW5jb2Q=";; pubkey) echo "cHViLWtleS0zMmJ5dGVzLWJhc2U2NC1lbmNvZGVkLXh4";; esac
EOF
      cat > /tmp/m_curl <<'EOF'
#!/bin/sh
echo "CURL_CALLED" >> /tmp/curl_calls
cat <<'JSON'
{"config":{"client_id":"I0q+","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700::2"}},"peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=","endpoint":{"host":"engage.cloudflareclient.com:2408"}}]}}
JSON
EOF
      chmod +x /tmp/m_awg /tmp/m_curl
  `;

  it("missing conf + warp target → registers, writes 0600 file, returns wg", async () => {
    const r = await exec(`
      ${PRELUDE}
      RAM=/tmp/ens_ram; rm -rf "$RAM" /tmp/curl_calls
      trap 'rm -rf "$DST" "$RAM" /tmp/curl_calls' EXIT

      AWG_BIN=/tmp/m_awg CURL=/tmp/m_curl SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
        let c = require("plugins.awg_warp.confstore");
        let item = { sec: "warp_a", iface: "warp_a", s: { warp_storage: "ram", awg_mimic: "auto" } };
        let wg = c.ensure({}, item, 1280, false);
        print(sprintf("%J", { ok: (wg != null), priv: (wg ? wg.private_key : ""),
          ep: (wg ? wg.endpoint : ""), jc_pos: (wg ? (wg.jc > 0) : false) }));
      '
      lsout=$(ls -la "$RAM/warp_a.conf" 2>/dev/null || echo "NONE")
      # ls -la outputs e.g. "-rw------- 1 root root 512 ... file"
      # OpenWrt BusyBox does not have stat; derive octal perms from ls mode bits
      case "$lsout" in
        -rw-------*) perms=600 ;;
        -rw-r--r--*) perms=644 ;;
        -rwxr-xr-x*) perms=755 ;;
        NONE) perms=NONE ;;
        *) perms=OTHER ;;
      esac
      has_priv=$(grep -c "PrivateKey" "$RAM/warp_a.conf" 2>/dev/null || true); has_priv=$((has_priv+0))
      printf '\n{"perms":"%s","has_priv":%d}\n' "$perms" "$has_priv"
    `);
    expect(r.exitCode).toBe(0);
    const lines = r.stdout.trim().split("\n");
    const wg = JSON.parse(lines[0]);
    const fileinfo = JSON.parse(lines[1]);
    expect(wg.ok).toBe(true);
    expect(wg.ep).toContain("engage.cloudflareclient.com:2408");
    expect(wg.jc_pos).toBe(true);
    expect(fileinfo.perms).toBe("600");
    expect(fileinfo.has_priv).toBeGreaterThan(0);
  });

  it("existing conf → does NOT register (curl never called), returns parsed wg", async () => {
    const r = await exec(`
      ${PRELUDE}
      RAM=/tmp/ens_ram2; rm -rf "$RAM" /tmp/curl_calls; mkdir -p "$RAM"
      trap 'rm -rf "$DST" "$RAM" /tmp/curl_calls' EXIT
      printf '%s\n' \
        "[Interface]" "PrivateKey = EXIST==" "Jc = 5" "Jmin = 64" "Jmax = 900" \
        "S1 = 0" "S2 = 0" "S3 = 0" "S4 = 0" "H1 = 1" "H2 = 2" "H3 = 3" "H4 = 4" \
        "Address = 10.9.8.7/32" "[Peer]" "PublicKey = EXISTPUB==" \
        "Endpoint = host.example:2408" "AllowedIPs = 0.0.0.0/0, ::/0" \
        > "$RAM/warp_b.conf"

      AWG_BIN=/tmp/m_awg CURL=/tmp/m_curl SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
        let c = require("plugins.awg_warp.confstore");
        let item = { sec: "warp_b", iface: "warp_b", s: { warp_storage: "ram" } };
        let wg = c.ensure({}, item, 1280, false);
        print(sprintf("%J", { priv: wg.private_key, jc: wg.jc, ep: wg.endpoint }));
      '
      curl_called=$(grep -c CURL_CALLED /tmp/curl_calls 2>/dev/null || true); curl_called=$((curl_called+0))
      printf '\n{"curl_called":%d}\n' "$curl_called"
    `);
    expect(r.exitCode).toBe(0);
    const lines = r.stdout.trim().split("\n");
    const wg = JSON.parse(lines[0]);
    const c = JSON.parse(lines[1]);
    expect(wg.priv).toBe("EXIST==");
    expect(wg.jc).toBe(5);
    expect(c.curl_called).toBe(0);
  });

  it("storage=ram drops a stale flash conf", async () => {
    const r = await exec(`
      ${PRELUDE}
      RAM=/tmp/ens_ram3; FLASH=/tmp/ens_flash3
      rm -rf "$RAM" "$FLASH" /tmp/curl_calls; mkdir -p "$FLASH"
      trap 'rm -rf "$DST" "$RAM" "$FLASH" /tmp/curl_calls' EXIT
      echo "stale" > "$FLASH/warp_c.conf"

      AWG_BIN=/tmp/m_awg CURL=/tmp/m_curl SINGBOX_TMPDIR="$RAM" SB_AWG_FLASH_DIR="$FLASH" \
        ucode -L '${LIB}' -e '
        let c = require("plugins.awg_warp.confstore");
        let item = { sec: "warp_c", iface: "warp_c", s: { warp_storage: "ram" } };
        c.ensure({}, item, 1280, false);
      '
      ram_exists=0; [ -f "$RAM/warp_c.conf" ] && ram_exists=1
      flash_exists=0; [ -f "$FLASH/warp_c.conf" ] && flash_exists=1
      printf '{"ram_exists":%d,"flash_exists":%d}\n' "$ram_exists" "$flash_exists"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.ram_exists).toBe(1);
    expect(o.flash_exists).toBe(0);
  });

  it("register failure (bad CF response) → returns null, no file written", async () => {
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"; DST="${LIB}/plugins/awg_warp"
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true
      RAM=/tmp/ens_fail; rm -rf "$RAM"
      trap 'rm -rf "$DST" "$RAM"' EXIT
      printf '#!/bin/sh\ncase "$1" in genkey) echo k;; pubkey) echo p;; esac\n' > /tmp/m_awg
      printf '#!/bin/sh\necho NOT_JSON\n' > /tmp/m_curl
      chmod +x /tmp/m_awg /tmp/m_curl

      AWG_BIN=/tmp/m_awg CURL=/tmp/m_curl SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
        let c = require("plugins.awg_warp.confstore");
        let item = { sec: "warp_f", iface: "warp_f", s: { warp_storage: "ram" } };
        let wg = c.ensure({}, item, 1280, false);
        print(sprintf("%J", { is_null: (wg == null) }));
      ' 2>/dev/null
      file_exists=0; [ -f "$RAM/warp_f.conf" ] && file_exists=1
      printf '\n{"file_exists":%d}\n' "$file_exists"
    `);
    expect(r.exitCode).toBe(0);
    const lines = r.stdout.trim().split("\n");
    expect(JSON.parse(lines[0]).is_null).toBe(true);
    expect(JSON.parse(lines[1]).file_exists).toBe(0);
  });

  it("selfhosted + missing conf → null (no auto-CF)", async () => {
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"; DST="${LIB}/plugins/awg_warp"
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true
      RAM=/tmp/ens_self; rm -rf "$RAM"
      trap 'rm -rf "$DST" "$RAM"' EXIT
      SINGBOX_TMPDIR="$RAM" ucode -L '${LIB}' -e '
        let c = require("plugins.awg_warp.confstore");
        let item = { sec: "warp_s", iface: "warp_s", s: { warp_storage: "ram", awg_target: "selfhosted" } };
        print(sprintf("%J", { is_null: (c.ensure({}, item, 1280, false) == null) }));
      '
    `);
    expect(r.exitCode).toBe(0);
    expect(JSON.parse(r.stdout).is_null).toBe(true);
  });
});

describe("awg confstore: path + render + parse", () => {
  useGuest();

  it("conf_path resolves ram/flash and round-trips render_conf→parse_full", async () => {
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      SINGBOX_TMPDIR=/tmp/sb_ram SB_AWG_FLASH_DIR=/etc/sb_flash \
        ucode -L '${LIB}' -e '
        let c = require("plugins.awg_warp.confstore");
        let wg = {
          private_key: "PRIV==", peer_public_key: "PUB==",
          address_v4: "172.16.0.2/32", address_v6: "2606:4700::2/128",
          endpoint: "engage.cloudflareclient.com:2408",
          jc: 8, jmin: 64, jmax: 900, s1: 0, s2: 0, s3: 0, s4: 0,
          h1: 1, h2: 2, h3: 3, h4: 4, i1: "<b 0xdead>",
        };
        let conf = c.render_conf(wg, 1280, true);
        let back = c.parse_full(conf);
        let setc = c.render_setconf(wg);
        print(sprintf("%J", {
          ram:   c.conf_path("warp_us", "ram"),
          flash: c.conf_path("warp_us", "flash"),
          rt_priv: back.private_key, rt_pub: back.peer_public_key,
          rt_ep: back.endpoint, rt_v4: back.address_v4, rt_v6: back.address_v6,
          rt_jc: back.jc, rt_i1: back.i1,
          setconf_has_addr: (index(setc, "Address") >= 0),
          setconf_has_mtu:  (index(setc, "MTU") >= 0),
        }));
      '
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.ram).toBe("/tmp/sb_ram/warp_us.conf");
    expect(o.flash).toBe("/etc/sb_flash/warp_us.conf");
    expect(o.rt_priv).toBe("PRIV==");
    expect(o.rt_pub).toBe("PUB==");
    expect(o.rt_ep).toBe("engage.cloudflareclient.com:2408");
    expect(o.rt_v4).toBe("172.16.0.2/32");
    expect(o.rt_v6).toBe("2606:4700::2/128");
    expect(o.rt_jc).toBe(8);
    expect(o.rt_i1).toBe("<b 0xdead>");
    expect(o.setconf_has_addr).toBe(false);
    expect(o.setconf_has_mtu).toBe(false);
  });
});
