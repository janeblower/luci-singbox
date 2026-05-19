#!/bin/sh
# tests/test_init_d.sh
# Drives /etc/init.d/singbox-ui start_service via stubbed ucode/uci and
# verifies parallel fetch, boot-mode env, and fail-fast on missing config.
set -e

INIT=luci-app-singbox-ui/root/etc/init.d/singbox-ui
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
