#!/bin/sh
# tests/test_init_d.sh
# Drives /etc/init.d/singbox-ui start_service via stubbed ucode/uci and
# verifies parallel fetch, boot-mode env, and fail-fast on missing config.
set -e

INIT=luci-singbox-ui/root/etc/init.d/singbox-ui
if [ ! -x "$INIT" ]; then
    echo "FAIL: $INIT not executable"; exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Stub bin: ucode, uci, logger, procd helpers.
mkdir -p "$TMPDIR/bin"

# ucode stub: log argv, touch the config file (the script checks `-s`).
cat >"$TMPDIR/bin/ucode" <<'EOF'
#!/bin/sh
echo "ucode $*" >>"$UCODE_LOG"
echo "SINGBOX_BOOT_FETCH=$SINGBOX_BOOT_FETCH" >>"$UCODE_LOG"
# Simulate generate.uc creating the config. The script now calls
# `ucode -L <lib> /path/to/generate.uc`, so scan all args for generate.uc.
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; break ;;
    esac
done
exit 0
EOF
chmod +x "$TMPDIR/bin/ucode"

# uci stub: return "0" so tproxy.enabled check skips nft apply.
cat >"$TMPDIR/bin/uci" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TMPDIR/bin/uci"

# logger stub.
cat >"$TMPDIR/bin/logger" <<'EOF'
#!/bin/sh
echo "logger $*" >>"$LOGGER_LOG"
EOF
chmod +x "$TMPDIR/bin/logger"

# procd stubs: record invocations.
for fn in procd_open_instance procd_set_param procd_close_instance; do
    cat >"$TMPDIR/bin/$fn" <<EOF
#!/bin/sh
echo "$fn \$*" >>"\$PROCD_LOG"
EOF
    chmod +x "$TMPDIR/bin/$fn"
done

# rc.common shim: defines stubs for start/stop, source the init.d.
cat >"$TMPDIR/rc.common" <<'EOF'
USE_PROCD=
START=
STOP=
EOF

# Capture logs.
export UCODE_LOG="$TMPDIR/ucode.log"
export LOGGER_LOG="$TMPDIR/logger.log"
export PROCD_LOG="$TMPDIR/procd.log"
: >"$UCODE_LOG"; : >"$LOGGER_LOG"; : >"$PROCD_LOG"

# Pre-clear config.
rm -f /tmp/singbox-ui.json

# Drive start_service by sourcing the init script in a shell that has procd
# stubs available. We bypass `#!/bin/sh /etc/rc.common` by sourcing directly.
PATH="$TMPDIR/bin:$PATH" sh -c "
    . '$PWD/$INIT'
    start_service
"

# 1) Both fetch invocations happened.
grep -q 'fetch-subs' "$UCODE_LOG"     || fail "fetch-subs not invoked"
grep -q 'fetch-rulesets' "$UCODE_LOG" || fail "fetch-rulesets not invoked"
pass "subs + rulesets fetched"

# 2) SINGBOX_BOOT_FETCH=1 was exported.
grep -q 'SINGBOX_BOOT_FETCH=1' "$UCODE_LOG" || fail "SINGBOX_BOOT_FETCH=1 missing from env"
pass "boot-fetch mode signalled"

# 3) procd_open_instance was reached (config was created by stub).
grep -q 'procd_open_instance' "$PROCD_LOG" || fail "procd_open_instance not called when config exists"
pass "happy path opens procd instance"

# nft apply must be gated on `nftables.uc needed` (stub ucode prints nothing to
# stdout, so the command substitution is empty → apply is skipped).
grep -q 'nftables.uc apply' "$UCODE_LOG" \
	&& fail "nft apply should be skipped when 'needed' returns empty"
pass "nft apply gated by 'needed'"

# C2.1.12: start_service must defensively `remove` any stale nft rules before
# deciding whether to (re)apply, so a config flipping from tproxy-required to
# direct-only no longer leaves a stranded table until the next stop.
grep -q 'nftables.uc remove' "$UCODE_LOG" \
	|| fail "C2.1.12: defensive 'nftables.uc remove' missing from start_service"
pass "C2.1.12: defensive nft remove before apply"

# ---- G4: apply failure is captured and logged ----
echo "-- G4: nft apply non-zero rc is logged via logger -t singbox-ui"
rm -f /tmp/singbox-ui.json
: >"$UCODE_LOG"; : >"$LOGGER_LOG"; : >"$PROCD_LOG"
# Stub that:
#   1. creates the config so we pass the fail-fast gate
#   2. returns "1" for the `needed` subcommand so apply runs
#   3. exits 1 for the `apply` subcommand so the new rc path is exercised
cat >"$TMPDIR/bin/ucode" <<'EOF'
#!/bin/sh
echo "ucode $*" >>"$UCODE_LOG"
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; exit 0 ;;
    esac
done
for _arg in "$@"; do
    case "$_arg" in
        needed)  echo 1; exit 0 ;;
        apply)   exit 1 ;;
    esac
done
exit 0
EOF
chmod +x "$TMPDIR/bin/ucode"
PATH="$TMPDIR/bin:$PATH" sh -c "
    . '$PWD/$INIT'
    start_service
" || true
grep -q 'nft apply failed' "$LOGGER_LOG" \
    || { echo "FAIL: G4 logger not invoked on apply failure"; cat "$LOGGER_LOG"; exit 1; }
pass "G4: apply rc=1 logged"

echo "-- G4: nft apply rc=0 does NOT log a failure"
rm -f /tmp/singbox-ui.json
: >"$UCODE_LOG"; : >"$LOGGER_LOG"; : >"$PROCD_LOG"
cat >"$TMPDIR/bin/ucode" <<'EOF'
#!/bin/sh
echo "ucode $*" >>"$UCODE_LOG"
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; exit 0 ;;
    esac
done
for _arg in "$@"; do
    case "$_arg" in
        needed)  echo 1; exit 0 ;;
    esac
done
# `apply` and `remove` succeed silently.
exit 0
EOF
chmod +x "$TMPDIR/bin/ucode"
PATH="$TMPDIR/bin:$PATH" sh -c "
    . '$PWD/$INIT'
    start_service
"
grep -q 'nft apply failed' "$LOGGER_LOG" \
    && { echo "FAIL: G4 false-positive failure log on rc=0"; cat "$LOGGER_LOG"; exit 1; }
pass "G4: apply rc=0 does not log failure"

# Restore the original happy-path ucode stub for any subsequent blocks.
cat >"$TMPDIR/bin/ucode" <<'EOF'
#!/bin/sh
echo "ucode $*" >>"$UCODE_LOG"
echo "SINGBOX_BOOT_FETCH=$SINGBOX_BOOT_FETCH" >>"$UCODE_LOG"
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; break ;;
    esac
done
exit 0
EOF
chmod +x "$TMPDIR/bin/ucode"

# ---- G7: stop_service silences stderr from `remove` ----
echo "-- G7: stop_service silences stderr from nftables.uc remove"
rm -f /tmp/singbox-ui.json
: >"$UCODE_LOG"; : >"$LOGGER_LOG"
# Stub that prints to stderr on every invocation. After stop_service the
# captured stderr must be empty (the redirection in init.d swallowed it).
cat >"$TMPDIR/bin/ucode" <<'EOF'
#!/bin/sh
echo "noisy ucode stderr" 1>&2
echo "ucode $*" >>"$UCODE_LOG"
exit 0
EOF
chmod +x "$TMPDIR/bin/ucode"
err=$(PATH="$TMPDIR/bin:$PATH" sh -c "
    . '$PWD/$INIT'
    stop_service
" 2>&1 >/dev/null) || true
echo "$err" | grep -q 'noisy ucode stderr' \
    && { echo "FAIL: G7 stop_service leaks stderr from remove"; echo "$err"; exit 1; }
grep -q 'nftables.uc remove' "$UCODE_LOG" \
    || { echo "FAIL: G7 stop_service didn't call remove"; cat "$UCODE_LOG"; exit 1; }
pass "G7: stop_service stderr suppressed"

# Restore the noisy-OK stub for the fail-fast block below.
cat >"$TMPDIR/bin/ucode" <<'EOF'
#!/bin/sh
echo "ucode $*" >>"$UCODE_LOG"
echo "SINGBOX_BOOT_FETCH=$SINGBOX_BOOT_FETCH" >>"$UCODE_LOG"
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; break ;;
    esac
done
exit 0
EOF
chmod +x "$TMPDIR/bin/ucode"

# ---- fail-fast branch ----
echo "-- start_service refuses to start when config is empty"
rm -f /tmp/singbox-ui.json
: >"$UCODE_LOG"; : >"$LOGGER_LOG"; : >"$PROCD_LOG"
# Override ucode stub to NOT touch /tmp/singbox-ui.json.
cat >"$TMPDIR/bin/ucode" <<'EOF'
#!/bin/sh
echo "ucode $*" >>"$UCODE_LOG"
exit 0
EOF
chmod +x "$TMPDIR/bin/ucode"

rc=0
PATH="$TMPDIR/bin:$PATH" sh -c "
    . '$PWD/$INIT'
    start_service
" || rc=$?

[ "$rc" != 0 ] || fail "start_service should have returned non-zero with no config"
grep -q 'refusing to start' "$LOGGER_LOG" || fail "expected logger message about refusal"
grep -q 'procd_open_instance' "$PROCD_LOG" && fail "procd_open_instance must not be called on fail-fast"
pass "fail-fast on missing config"

echo "OK"
