import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const NFT = `${LIB}/../nftables.uc`; // entry point sits one level up from lib

describe("test_plugin_lifecycle", () => {
  useGuest();

  it("nft ruleset includes a plugin-contributed fragment (dry-run print)", async () => {
    const r = await exec(`
      set -e
      PLUG="${LIB}/plugins/zz_nft"
      mkdir -p "$PLUG"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_nft", nft: { fragment: function(cur){ return "table inet zz_nft_marker { }"; } } });
return {};
EOF
      # Use the nftables.uc CLI 'print' path (no actual nft apply) with the stub apply seam.
      out=$(UCODE_APP_LIB_DIR="${LIB}" SINGBOX_NFT_APPLY=/bin/true ucode -L '${LIB}' '${LIB}/../nftables.uc' print 2>/dev/null || true)
      rm -rf "$PLUG"
      echo "$out" | grep -q "zz_nft_marker" && echo FOUND || echo MISSING
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().endsWith("FOUND")).toBe(true);
  });
});
