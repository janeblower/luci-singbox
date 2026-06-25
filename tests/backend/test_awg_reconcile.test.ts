import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";

describe("awg iface helpers", () => {
  useGuest();
  it("sanitizes interface names and computes MTU via override", async () => {
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      ucode -L '${LIB}' -e '
        let h = require("plugins.awg_warp.iface");
        print(sprintf("%J", {
          n1: h.iface_name("warp_us"),
          n2: h.iface_name("My WARP #1!! tooooo long name"),
          n3: h.iface_name(""),
          mtu_override: h.effective_mtu({}, "1380"),
          wan_mtu_positive: (h.wan_mtu({}) > 0),
        }));
      '
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.n1).toBe("warp_us");
    expect(o.n2).toMatch(/^[a-z0-9_]{1,15}$/);
    expect(o.n3).toBe("awg");
    expect(o.mtu_override).toBe(1380);
    expect(o.wan_mtu_positive).toBe(true);
  });
});

describe("awg reconcile", () => {
  useGuest();

  it("apply issues native ip/awg commands; setconf excludes Address/MTU; addrlabel gated on ipv6", async () => {
    // Creds come from a pre-placed .conf in $SINGBOX_TMPDIR (confstore source of truth).
    // UCI section carries only type/enabled/warp_storage/ipv6_enabled/mtu_override.
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_rci_uci
      LOG=/tmp/awg_rci_cmds
      SETCONF=/tmp/awg_rci_sc
      M_IP=/tmp/awg_rci_ip
      M_AWG=/tmp/awg_rci_awg
      RAM=/tmp/awg_rci_ram
      trap 'rm -rf "$DST" "$UCFG" "$LOG" "$SETCONF" "$M_IP" "$M_AWG" "$RAM"' EXIT
      mkdir -p "$DST" && cp -r "$SRC"/. "$DST"/ 2>/dev/null

      rm -f "$LOG"
      # Write mock stubs — printf expands shell vars into the script body at write time
      printf '#!/bin/sh\necho "ip $@" >> %s\nexit 0\n' "$LOG" > "$M_IP"
      printf '#!/bin/sh\necho "awg $@" >> %s\n[ "$1" = "setconf" ] && cp "$3" %s 2>/dev/null\nexit 0\n' "$LOG" "$SETCONF" > "$M_AWG"
      chmod +x "$M_IP" "$M_AWG"

      # Pre-place the .conf seed in SINGBOX_TMPDIR (confstore reads it for source of truth).
      mkdir -p "$RAM"
      cat > "$RAM/warp_t.conf" << 'WGEOF'
[Interface]
PrivateKey = PRIV==
Jc = 8
Jmin = 64
Jmax = 900
S1 = 0
S2 = 0
S3 = 0
S4 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
Address = 172.16.0.2/32
Address = 2606:4700::2/128
MTU = 1380
[Peer]
PublicKey = PUB==
Endpoint = engage.cloudflareclient.com:2408
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WGEOF

      # Seed UCI config — no warp_* cred fields; creds come from .conf
      mkdir -p "$UCFG"
      printf '%s\n' \
        "config outbound 'warp_t'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option warp_storage 'ram'" \
        "	option ipv6_enabled '1'" \
        "	option mtu_override '1380'" \
        > "$UCFG/singbox-ui"

      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      setconf=$(cat "$SETCONF" 2>/dev/null || true)
      # grep -c prints count even on 0 matches (exits 1); || true suppresses that
      # exit under set -e. Arithmetic +0 coerces empty/missing to 0.
      has_link=$(grep -c "link add dev warp_t type amneziawg" "$LOG" 2>/dev/null || true); has_link=$((has_link+0))
      has_v6=$(grep -c "addr add 2606:4700::2/128" "$LOG" 2>/dev/null || true); has_v6=$((has_v6+0))
      has_mtu=$(grep -c "mtu 1380" "$LOG" 2>/dev/null || true); has_mtu=$((has_mtu+0))
      has_label=$(grep -c "addrlabel add" "$LOG" 2>/dev/null || true); has_label=$((has_label+0))
      bad_setconf=$(printf '%s' "$setconf" | grep -ci '^Address\|^MTU' 2>/dev/null || true); bad_setconf=$((bad_setconf+0))
      printf '{"link":%d,"v6":%d,"mtu":%d,"label":%d,"bad_setconf":%d}\n' \
        "$has_link" "$has_v6" "$has_mtu" "$has_label" "$bad_setconf"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.link).toBeGreaterThan(0);
    expect(o.v6).toBeGreaterThan(0);
    expect(o.mtu).toBeGreaterThan(0);
    expect(o.label).toBeGreaterThan(0);
    expect(o.bad_setconf).toBe(0);
  });

  it("FIX-1: disabling a section (enabled=0) also removes addrlabel entries", async () => {
    // Prove the addrlabel leak fix: enable a section with ipv6 and a pre-placed .conf,
    // apply, then set enabled=0, apply again — the second apply must emit BOTH link del
    // AND addrlabel del for that interface (_managed_names reads del_v6 from .conf).
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_fix1_uci
      LOG=/tmp/awg_fix1_cmds
      M_IP=/tmp/awg_fix1_ip
      M_AWG=/tmp/awg_fix1_awg
      RAM=/tmp/awg_fix1_ram
      trap 'rm -rf "$DST" "$UCFG" "$LOG" "$M_IP" "$M_AWG" "$RAM"' EXIT
      mkdir -p "$DST" && cp -r "$SRC"/. "$DST"/ 2>/dev/null

      printf '#!/bin/sh\necho "ip $@" >> %s\nexit 0\n' "$LOG" > "$M_IP"
      printf '#!/bin/sh\nexit 0\n' > "$M_AWG"
      chmod +x "$M_IP" "$M_AWG"

      # Pre-place .conf with v6 address — this is the source of truth for del_v6
      mkdir -p "$RAM"
      cat > "$RAM/warp_dis.conf" << 'WGEOF'
[Interface]
PrivateKey = PRIV==
Jc = 8
Jmin = 64
Jmax = 900
S1 = 0
S2 = 0
S3 = 0
S4 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
Address = 10.0.0.2/32
Address = 2606:4700::9/128
MTU = 1280
[Peer]
PublicKey = PUB==
Endpoint = engage.cloudflareclient.com:2408
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WGEOF

      mkdir -p "$UCFG"
      # First apply: section enabled=1 — no warp_* creds in UCI, come from .conf
      printf '%s\n' \
        "config outbound 'warp_dis'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option warp_storage 'ram'" \
        "	option ipv6_enabled '1'" \
        > "$UCFG/singbox-ui"

      rm -f "$LOG"
      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      # Second apply: same section but enabled=0 — .conf still present, del_v6 sourced from it
      printf '%s\n' \
        "config outbound 'warp_dis'" \
        "	option type 'awg_warp'" \
        "	option enabled '0'" \
        "	option warp_storage 'ram'" \
        "	option ipv6_enabled '1'" \
        > "$UCFG/singbox-ui"

      rm -f "$LOG"
      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      # The second apply (disable path) must emit link del AND addrlabel del
      # (.conf is still present so _managed_names finds del_v6 = 2606:4700::9/128)
      has_link_del=$(grep -c "link del dev warp_dis" "$LOG" 2>/dev/null || true); has_link_del=$((has_link_del+0))
      has_addrlabel_del=$(grep -c "addrlabel del prefix 2606:4700::9/128" "$LOG" 2>/dev/null || true); has_addrlabel_del=$((has_addrlabel_del+0))
      has_default_del=$(grep -c "addrlabel del prefix ::/0" "$LOG" 2>/dev/null || true); has_default_del=$((has_default_del+0))
      printf '{"link_del":%d,"addrlabel_del":%d,"default_del":%d}\n' \
        "$has_link_del" "$has_addrlabel_del" "$has_default_del"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.link_del).toBeGreaterThan(0);
    expect(o.addrlabel_del).toBeGreaterThan(0);
    expect(o.default_del).toBeGreaterThan(0);
  });

  it("FIX-3: malicious address_v6 in stored .conf del path is sanitized — ip addrlabel del is not called with injected content", async () => {
    // Prove safe_cidr() guards the DELETE path in _del_iface:
    // _managed_names reads del_v6 from the stored .conf. When that .conf contains
    // a malicious address_v6, safe_cidr() in _del_iface must reject it so the
    // marker file is NOT created. link del must still be called (unaffected).
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_fix3_uci
      LOG=/tmp/awg_fix3_cmds
      M_IP=/tmp/awg_fix3_ip
      M_AWG=/tmp/awg_fix3_awg
      RAM=/tmp/awg_fix3_ram
      MARKER=/tmp/awg_fix3_pwned
      trap 'rm -rf "$DST" "$UCFG" "$LOG" "$M_IP" "$M_AWG" "$RAM" "$MARKER"' EXIT
      mkdir -p "$DST" && cp -r "$SRC"/. "$DST"/ 2>/dev/null

      rm -f "$MARKER"
      # Mock ip: log args AND eval them (simulates shell injection)
      printf '#!/bin/sh\necho "ip $@" >> %s\neval "$@" 2>/dev/null || true\nexit 0\n' "$LOG" > "$M_IP"
      printf '#!/bin/sh\nexit 0\n' > "$M_AWG"
      chmod +x "$M_IP" "$M_AWG"

      # Pre-place a valid .conf for first apply (enabled=1)
      mkdir -p "$RAM"
      cat > "$RAM/warp_evil6.conf" << 'WGEOF'
[Interface]
PrivateKey = PRIV==
Jc = 8
Jmin = 64
Jmax = 900
S1 = 0
S2 = 0
S3 = 0
S4 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
Address = 10.0.0.5/32
Address = 2001:db8::1/128
MTU = 1280
[Peer]
PublicKey = PUB==
Endpoint = engage.cloudflareclient.com:2408
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WGEOF

      mkdir -p "$UCFG"
      # First apply: section enabled=1
      printf '%s\n' \
        "config outbound 'warp_evil6'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option warp_storage 'ram'" \
        "	option ipv6_enabled '1'" \
        > "$UCFG/singbox-ui"

      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      # Overwrite .conf with malicious address_v6 — this is what _managed_names reads for del_v6.
      # safe_cidr() in _del_iface must reject it.
      # Use printf so the shell variable $MARKER is expanded correctly at runtime
      # (not interpolated by JS template literal).
      printf '%s\n' \
        "[Interface]" \
        "PrivateKey = PRIV==" \
        "Jc = 8" \
        "Jmin = 64" \
        "Jmax = 900" \
        "S1 = 0" \
        "S2 = 0" \
        "S3 = 0" \
        "S4 = 0" \
        "H1 = 1" \
        "H2 = 2" \
        "H3 = 3" \
        "H4 = 4" \
        "Address = 10.0.0.5/32" \
        "Address = 2001:db8::1/128; touch \${MARKER}" \
        "MTU = 1280" \
        "[Peer]" \
        "PublicKey = PUB==" \
        "Endpoint = engage.cloudflareclient.com:2408" \
        "AllowedIPs = 0.0.0.0/0, ::/0" \
        "PersistentKeepalive = 25" \
        > "$RAM/warp_evil6.conf"

      # Second apply: section disabled — _managed_names reads del_v6 from the malicious .conf
      rm -f "$MARKER"
      printf '%s\n' \
        "config outbound 'warp_evil6'" \
        "	option type 'awg_warp'" \
        "	option enabled '0'" \
        "	option warp_storage 'ram'" \
        "	option ipv6_enabled '1'" \
        > "$UCFG/singbox-ui"

      rm -f "$LOG"
      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      # Marker must NOT exist (injection blocked by safe_cidr in _del_iface)
      marker_exists=0
      [ -f "$MARKER" ] && marker_exists=1
      # addrlabel del must not contain the malicious payload
      addrlabel_evil=$(grep -c "addrlabel del.*touch" "$LOG" 2>/dev/null || true); addrlabel_evil=$((addrlabel_evil+0))
      # link del must still have been called (safe part of _del_iface is unaffected)
      link_del=$(grep -c "link del dev warp_evil6" "$LOG" 2>/dev/null || true); link_del=$((link_del+0))
      printf '{"marker_exists":%d,"addrlabel_evil":%d,"link_del":%d}\n' \
        "$marker_exists" "$addrlabel_evil" "$link_del"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.marker_exists).toBe(0);
    expect(o.addrlabel_evil).toBe(0);
    expect(o.link_del).toBeGreaterThan(0);
  });

  it("FIX-4: malicious endpoint in stored .conf is rejected — interface not brought up, setconf not written", async () => {
    // Prove safe_endpoint() guards the setconf path after ensure():
    // A crafted Endpoint in .conf containing disallowed characters (e.g. a space
    // followed by injected directives) is rejected by safe_endpoint() in _bring_up
    // after confstore.ensure() returns the parsed wg object.
    // safe_endpoint() only allows [a-zA-Z0-9._:-]; a space causes rejection →
    // _bring_up returns early → awg setconf never called → no injected content.
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_fix4_uci
      LOG=/tmp/awg_fix4_cmds
      SETCONF=/tmp/awg_fix4_sc
      M_IP=/tmp/awg_fix4_ip
      M_AWG=/tmp/awg_fix4_awg
      RAM=/tmp/awg_fix4_ram
      trap 'rm -rf "$DST" "$UCFG" "$LOG" "$SETCONF" "$M_IP" "$M_AWG" "$RAM"' EXIT
      mkdir -p "$DST" && cp -r "$SRC"/. "$DST"/ 2>/dev/null

      rm -f "$LOG" "$SETCONF"
      printf '#!/bin/sh\necho "ip $@" >> %s\nexit 0\n' "$LOG" > "$M_IP"
      printf '#!/bin/sh\necho "awg $@" >> %s\n[ "$1" = "setconf" ] && cp "$3" %s 2>/dev/null\nexit 0\n' "$LOG" "$SETCONF" > "$M_AWG"
      chmod +x "$M_IP" "$M_AWG"

      # Pre-place .conf with a malicious Endpoint value containing a space followed by
      # injected setconf directives. parse_full() reads this as the Endpoint value
      # (everything after '=' on that line). safe_endpoint() in reconcile rejects it
      # because spaces are not in [a-zA-Z0-9._:-] → _bring_up aborts → no setconf.
      mkdir -p "$RAM"
      printf '%s\n' \
        "[Interface]" \
        "PrivateKey = PRIV==" \
        "Jc = 8" \
        "Jmin = 64" \
        "Jmax = 900" \
        "S1 = 0" \
        "S2 = 0" \
        "S3 = 0" \
        "S4 = 0" \
        "H1 = 1" \
        "H2 = 2" \
        "H3 = 3" \
        "H4 = 4" \
        "Address = 172.16.0.2/32" \
        "MTU = 1280" \
        "[Peer]" \
        "PublicKey = PUB==" \
        "Endpoint = engage.cloudflareclient.com:2408 [Peer] PublicKey = ATTACKER= AllowedIPs = 0.0.0.0/0" \
        "AllowedIPs = 0.0.0.0/0, ::/0" \
        "PersistentKeepalive = 25" \
        > "$RAM/warp_ep.conf"

      # UCI section — no warp_* cred fields; creds come from .conf
      mkdir -p "$UCFG"
      printf '%s\n' \
        "config outbound 'warp_ep'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option warp_storage 'ram'" \
        "	option ipv6_enabled '0'" \
        > "$UCFG/singbox-ui"

      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      setconf_content=$(cat "$SETCONF" 2>/dev/null || true)
      # Check setconf was NOT written (interface skipped due to bad endpoint)
      setconf_written=0
      [ -f "$SETCONF" ] && setconf_written=1
      # If somehow written, check for injected content
      has_attacker=$(printf '%s' "$setconf_content" | grep -c "ATTACKER" 2>/dev/null || true); has_attacker=$((has_attacker+0))
      # awg setconf must not have been called at all
      awg_setconf_called=$(grep -c "awg setconf" "$LOG" 2>/dev/null || true); awg_setconf_called=$((awg_setconf_called+0))
      printf '{"setconf_written":%d,"has_attacker":%d,"awg_setconf_called":%d}\n' \
        "$setconf_written" "$has_attacker" "$awg_setconf_called"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    // Malformed endpoint → _bring_up returns early → awg setconf never called
    expect(o.awg_setconf_called).toBe(0);
    expect(o.setconf_written).toBe(0);
    expect(o.has_attacker).toBe(0);
  });

  it("FIX-2: malicious address_v4 in stored .conf is sanitized — ip addr add is not called with injected content", async () => {
    // Prove the safe_cidr sanitizer applied after confstore.ensure():
    // an address_v4 in .conf containing shell metacharacters must NOT reach
    // the `ip addr add` command — the interface must not be brought up with
    // the bad address, and no marker file must be created.
    const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_fix2_uci
      LOG=/tmp/awg_fix2_cmds
      M_IP=/tmp/awg_fix2_ip
      M_AWG=/tmp/awg_fix2_awg
      RAM=/tmp/awg_fix2_ram
      MARKER=/tmp/awg_fix2_pwned
      trap 'rm -rf "$DST" "$UCFG" "$LOG" "$M_IP" "$M_AWG" "$RAM" "$MARKER"' EXIT
      mkdir -p "$DST" && cp -r "$SRC"/. "$DST"/ 2>/dev/null

      rm -f "$MARKER"
      printf '#!/bin/sh\necho "ip $@" >> %s\n# execute any inline command passed as an arg (simulates injection)\neval "$@" 2>/dev/null || true\nexit 0\n' "$LOG" > "$M_IP"
      printf '#!/bin/sh\nexit 0\n' > "$M_AWG"
      chmod +x "$M_IP" "$M_AWG"

      # Pre-place .conf with malicious address_v4 — would inject a command if passed
      # unsanitized to shell. safe_cidr() in _bring_up must reject it after ensure().
      # Use printf so the shell variable $MARKER is expanded correctly at runtime
      # (not interpolated by JS template literal).
      mkdir -p "$RAM"
      printf '%s\n' \
        "[Interface]" \
        "PrivateKey = PRIV==" \
        "Jc = 8" \
        "Jmin = 64" \
        "Jmax = 900" \
        "S1 = 0" \
        "S2 = 0" \
        "S3 = 0" \
        "S4 = 0" \
        "H1 = 1" \
        "H2 = 2" \
        "H3 = 3" \
        "H4 = 4" \
        "Address = 1.2.3.4/32; touch \${MARKER}" \
        "MTU = 1280" \
        "[Peer]" \
        "PublicKey = PUB==" \
        "Endpoint = engage.cloudflareclient.com:2408" \
        "AllowedIPs = 0.0.0.0/0, ::/0" \
        "PersistentKeepalive = 25" \
        > "$RAM/warp_evil.conf"

      # UCI section — no warp_* cred fields; creds come from .conf
      mkdir -p "$UCFG"
      printf '%s\n' \
        "config outbound 'warp_evil'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option warp_storage 'ram'" \
        "	option ipv6_enabled '0'" \
        > "$UCFG/singbox-ui"

      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      # Marker must NOT exist (injection was blocked by safe_cidr)
      marker_exists=0
      [ -f "$MARKER" ] && marker_exists=1
      # ip addr add must not have been called with the evil address
      addr_add_evil=$(grep -c "addr add.*touch" "$LOG" 2>/dev/null || true); addr_add_evil=$((addr_add_evil+0))
      printf '{"marker_exists":%d,"addr_add_evil":%d}\n' "$marker_exists" "$addr_add_evil"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.marker_exists).toBe(0);
    expect(o.addr_add_evil).toBe(0);
  });
});
