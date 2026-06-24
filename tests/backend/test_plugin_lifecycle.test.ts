import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";

describe("test_plugin_lifecycle", () => {
  useGuest();

  it("nft ruleset includes a plugin-contributed fragment (dry-run print)", async () => {
    const r = await exec(`
      set -e
      PLUG="${LIB}/plugins/zz_nft"
      trap 'rm -rf "$PLUG"' EXIT
      mkdir -p "$PLUG"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_nft", nft: { fragment: function(cur){ return "table inet zz_nft_marker { }"; } } });
return {};
EOF
      # Use the nftables.uc CLI 'print' path (no actual nft apply) with the stub apply seam.
      out=$(UCODE_APP_LIB_DIR="${LIB}" SINGBOX_NFT_APPLY=/bin/true ucode -L '${LIB}' '${LIB}/../nftables.uc' print 2>/dev/null || true)
      echo "$out" | grep -q "zz_nft_marker" && echo FOUND || echo MISSING
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().endsWith("FOUND")).toBe(true);
  });

  // Regression test for the forward-compat defect: plugin fragments must be
  // applied via the `apply` path even when no transparent tproxy/tun inbound
  // is configured (i.e. p.transparent=0). Previously _cmd_apply_locked would
  // early-return before reaching append_plugin_fragments in this case.
  // Uses SINGBOX_NFT_CAPTURE seam: ucode writes the would-be applied ruleset
  // to the capture file instead of invoking `nft -f`.
  it("apply path applies plugin fragment when no transparent inbound (tproxy-less fix)", async () => {
    const r = await exec(`
      D=/tmp/plc-apply-test-$$
      PLUG="${LIB}/plugins/zz_apply_marker"
      trap 'rm -rf "$PLUG" "$D"' EXIT
      mkdir -p "$PLUG" "$D/uci"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_apply_marker", nft: { fragment: function(cur){ return "table inet zz_apply_marker_table { }"; } } });
return {};
EOF
      # Minimal UCI config: no tproxy/tun inbound — transparent=0.
      printf '' > "$D/uci/singbox-ui"
      # Run the apply path with SINGBOX_NFT_CAPTURE seam: captures the assembled
      # ruleset to $D/captured instead of invoking nft, returns 0.
      UCI_CONFIG_DIR="$D/uci" \
        UCODE_APP_LIB_DIR="${LIB}" \
        SINGBOX_NFT_CAPTURE="$D/captured" \
        ucode -L "${LIB}" "${LIB}/../nftables.uc" apply 2>/dev/null
      rc=$?
      captured=$(cat "$D/captured" 2>/dev/null || echo "")
      if [ $rc -ne 0 ]; then echo "APPLY_FAILED:rc=$rc"; exit 0; fi
      echo "$captured" | grep -q "zz_apply_marker_table" && echo FOUND || echo MISSING
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().endsWith("FOUND")).toBe(true);
  });

  it("apply-plugins runs a plugin lifecycle.apply hook", async () => {
    const r = await exec(`
      set -e
      PLUG="${LIB}/plugins/zz_lc"
      trap 'rm -rf "$PLUG"; rm -f /tmp/zz_lc_applied /tmp/zz_lc_torndown' EXIT
      mkdir -p "$PLUG"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
let fs = require("fs");
reg.register({ name: "zz_lc", lifecycle: {
  apply: function(cur){ fs.writefile("/tmp/zz_lc_applied", "1"); },
  teardown: function(cur){ fs.writefile("/tmp/zz_lc_torndown", "1"); } } });
return {};
EOF
      rm -f /tmp/zz_lc_applied /tmp/zz_lc_torndown
      UCODE_APP_LIB_DIR="${LIB}" ucode -L '${LIB}' '${LIB}/../apply-plugins.uc' apply
      UCODE_APP_LIB_DIR="${LIB}" ucode -L '${LIB}' '${LIB}/../apply-plugins.uc' teardown
      a=$([ -f /tmp/zz_lc_applied ] && echo 1 || echo 0)
      t=$([ -f /tmp/zz_lc_torndown ] && echo 1 || echo 0)
      echo "{\\"applied\\":$a,\\"torndown\\":$t}"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.applied).toBe(1);
    expect(o.torndown).toBe(1);
  });

  // Regression test for the third early-return branch in _cmd_apply_locked:
  // transparent inbound IS configured BUT there are no fakeip ranges AND no
  // rule-set rules.  Previously `return 0` dropped frags; now it mirrors the
  // !p.transparent branch and calls run_nft_ruleset(frags) when frags exist.
  // Uses SINGBOX_NFT_CAPTURE seam so no actual nft binary is needed.
  it("apply path applies plugin fragment when transparent inbound but no fakeip/rules (third-branch fix)", async () => {
    const r = await exec(`
      D=/tmp/plc-tproxy-nofakeip-$$
      PLUG="${LIB}/plugins/zz_tproxy_frag"
      trap 'rm -rf "$PLUG" "$D"' EXIT
      mkdir -p "$PLUG" "$D/uci"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_tproxy_frag", nft: { fragment: function(cur){ return "table inet zz_tproxy_frag_marker { }"; } } });
return {};
EOF
      # UCI config: one tproxy inbound with nft_rules=1 but no fakeip ranges
      # and no rule-set sections — triggers the v4==""&&v6==""&&!length(rules) branch.
      cat > "$D/uci/singbox-ui" <<'UCEOF'
config singbox-ui main
	option enabled 1

config inbound tproxy_in
	option type tproxy
	option listen_port 7895
	option nft_rules 1
UCEOF
      UCI_CONFIG_DIR="$D/uci" \
        UCODE_APP_LIB_DIR="${LIB}" \
        SINGBOX_NFT_CAPTURE="$D/captured" \
        ucode -L "${LIB}" "${LIB}/../nftables.uc" apply 2>/dev/null
      rc=$?
      captured=$(cat "$D/captured" 2>/dev/null || echo "")
      if [ $rc -ne 0 ]; then echo "APPLY_FAILED:rc=$rc"; exit 0; fi
      echo "$captured" | grep -q "zz_tproxy_frag_marker" && echo FOUND || echo MISSING
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().endsWith("FOUND")).toBe(true);
  });

  // Confirm: !transparent + no plugin fragments → apply returns 0 cleanly
  // and does NOT invoke run_nft_ruleset (no capture file created).
  it("apply path with no transparent inbound and no plugin fragments returns 0 without applying ruleset", async () => {
    const r = await exec(`
      D=/tmp/plc-nofrag-test-$$
      mkdir -p "$D/uci"
      printf '' > "$D/uci/singbox-ui"
      UCI_CONFIG_DIR="$D/uci" \
        UCODE_APP_LIB_DIR="${LIB}" \
        SINGBOX_NFT_CAPTURE="$D/captured" \
        ucode -L "${LIB}" "${LIB}/../nftables.uc" apply 2>/dev/null
      rc=$?
      captured_exists=0
      [ -f "$D/captured" ] && captured_exists=1
      rm -rf "$D"
      if [ $rc -ne 0 ]; then echo "FAILED:rc=$rc"; exit 0; fi
      # No fragments, no transparent inbound: run_nft_ruleset must NOT be called.
      [ $captured_exists -eq 0 ] && echo NO_APPLY || echo UNEXPECTED_APPLY
      echo CLEAN_EXIT
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("NO_APPLY");
    expect(r.stdout).toContain("CLEAN_EXIT");
  });
});
