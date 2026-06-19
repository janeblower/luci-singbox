import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Port of tests/backend/test_nftables_ip_rule_smoke.sh
// PATH-stub `ip` to feed canned `ip rule show` output to nftables.uc,
// assert a warning fires when no matching fwmark is present and stays
// silent when one is.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nftables.uc`;

// Shared UCI config fixture that cmd_apply needs
const UCI_CONFIG = `config global
\toption fwmark '0x1'
\toption fwmark_mask '0x1'
config dns_server fakeip
\toption type 'fakeip'
\toption enabled '1'
\toption inet4_range '198.18.0.0/15'
\toption inet6_range 'fc00::/18'
config inbound tp
\toption protocol 'tproxy'
\toption enabled '1'
\toption nft_rules '1'
\toption listen_port '7895'
\tlist interface 'br-lan'
`;

describe("test_nftables_ip_rule_smoke", () => {
  useGuest();

  it("warns when no matching ip rule with fwmark", async () => {
    const r = await exec(`
      TMPDIR=$(mktemp -d)
      UCI="$TMPDIR/uci"; mkdir -p "$UCI"
      cat >"$UCI/singbox-ui" <<'EOCONF'
${UCI_CONFIG}
EOCONF

      STUB="$TMPDIR/bin"; mkdir -p "$STUB"
      cat >"$STUB/ip" <<'EOIP'
#!/bin/sh
if [ "$2" = "rule" ] && [ "$3" = "show" ]; then
  [ "$MOCK_HAS_RULE" = "1" ] && echo "100: from all fwmark 0x1/0x1 lookup 100" || true
fi
EOIP
      chmod +x "$STUB/ip"

      cat >"$STUB/nft" <<'EONFT'
#!/bin/sh
case "$1" in
  -f) cat >/dev/null; exit 0 ;;
  delete) exit 0 ;;
  *) exit 0 ;;
esac
EONFT
      chmod +x "$STUB/nft"

      out=$(PATH="$STUB:$PATH" UCI_CONFIG_DIR="$UCI" MOCK_HAS_RULE=0 \
        ucode -L '${LIB}' '${SCRIPT}' apply 2>&1) || true
      rm -rf "$TMPDIR"
      printf '%s' "$out"
    `);

    expect(r.stdout).toContain("no ip rule with fwmark 0x1/0x1");
  });

  it("stays quiet when matching ip rule is present", async () => {
    const r = await exec(`
      TMPDIR=$(mktemp -d)
      UCI="$TMPDIR/uci"; mkdir -p "$UCI"
      cat >"$UCI/singbox-ui" <<'EOCONF'
${UCI_CONFIG}
EOCONF

      STUB="$TMPDIR/bin"; mkdir -p "$STUB"
      cat >"$STUB/ip" <<'EOIP'
#!/bin/sh
if [ "$2" = "rule" ] && [ "$3" = "show" ]; then
  [ "$MOCK_HAS_RULE" = "1" ] && echo "100: from all fwmark 0x1/0x1 lookup 100" || true
fi
EOIP
      chmod +x "$STUB/ip"

      cat >"$STUB/nft" <<'EONFT'
#!/bin/sh
case "$1" in
  -f) cat >/dev/null; exit 0 ;;
  delete) exit 0 ;;
  *) exit 0 ;;
esac
EONFT
      chmod +x "$STUB/nft"

      out=$(PATH="$STUB:$PATH" UCI_CONFIG_DIR="$UCI" MOCK_HAS_RULE=1 \
        ucode -L '${LIB}' '${SCRIPT}' apply 2>&1) || true
      rm -rf "$TMPDIR"
      printf '%s' "$out"
    `);

    expect(r.stdout).not.toContain("no ip rule with fwmark");
  });
});
