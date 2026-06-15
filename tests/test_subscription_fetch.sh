#!/bin/sh
# Unit-tests subscription.uc curl fetch wiring with injected seams (no curl, no net).
set -eu
LIB="luci-singbox-ui/root/usr/share/singbox-ui"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export UCI_CONFIG_DIR="$WORK/config"; mkdir -p "$UCI_CONFIG_DIR"
cat > "$UCI_CONFIG_DIR/singbox-ui" <<'UCI'
config outbound 'mysub'
	option type 'subscription'
	option sub_url 'https://sub.example.com/x'
	option sub_user_agent 'v2rayNG/1.8.5'
	option sub_interval '3600'

config outbound 'mysub2'
	option type 'subscription'
	option sub_url 'https://sub.example.com/y'
UCI

# Test A: cmd_fetch_subs builds one job per enabled subscription carrying url + ua,
# and NO ephemeral config (curl path, fetched directly).
mkdir -p "$WORK/tmp"
cat > "$WORK/probe.uc" <<UC
let sub = require("subscription");
let captured = [];
sub._set_fetcher_for_test(function(jobs){
  for (let j in jobs)
    push(captured, { name:j.name, url:j.url, ua:j.ua,
                     has_cfg:(exists(j, "cfg_json")) });
  let fs = require("fs");
  for (let j in jobs) { let f = fs.open(j.body_path,"w"); f.write("trojan://x\@h:1#n\n"); f.close(); }
});
let uci = require("uci").cursor("$UCI_CONFIG_DIR");
sub._cmd_fetch_subs_for_test(uci);
print(sprintf("%J", captured));
UC
SINGBOX_TMPDIR="$WORK/tmp" "$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe.uc" > "$WORK/cap.json"
grep -q 'sub.example.com/x' "$WORK/cap.json" || { echo "FAIL: job url missing"; cat "$WORK/cap.json"; exit 1; }
grep -q 'v2rayNG' "$WORK/cap.json"           || { echo "FAIL: job ua not passed"; cat "$WORK/cap.json"; exit 1; }
grep -q '"has_cfg": false' "$WORK/cap.json"  || { echo "FAIL: ephemeral cfg should be gone"; cat "$WORK/cap.json"; exit 1; }

# Test B: build_fetch_config seam is removed.
cat > "$WORK/probe2.uc" <<UC
let sub = require("subscription");
print(exists(sub, "_build_fetch_config_for_test") ? "present" : "absent");
UC
out2="$("$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe2.uc")"
[ "$out2" = "absent" ] || { echo "FAIL: _build_fetch_config_for_test still exported"; exit 1; }

# Test C: the REAL _fetcher invokes curl with the expected argv — proves
# helpers.sq() quoting holds and DEFAULT_UA fallback fires for an empty UA.
REC="$WORK/curl-rec.sh"
cat > "$REC" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$ARGV_LOG"
# emulate curl: write body to -o target so downstream parse succeeds
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf 'trojan://x@h:1#n\n' > "$out"
exit 0
EOF
chmod +x "$REC"
export ARGV_LOG="$WORK/argv.log"; : > "$ARGV_LOG"

cat > "$WORK/probeC.uc" <<UC
let sub = require("subscription");
sub._fetcher_real_for_test([
  { name:"s1", url:"https://h/x?a=1&b=2", ua:"Custom UA/1.0",
    hdr_path:"$WORK/s1.hdr", body_path:"$WORK/s1.body", opts:{timeout:9} },
  { name:"s2", url:"https://h/y", ua:"",
    hdr_path:"$WORK/s2.hdr", body_path:"$WORK/s2.body", opts:{timeout:9} },
]);
UC
CURL="$REC" "$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probeC.uc"
# url + custom UA appear as single argv tokens (quoting preserved the '&' and space)
grep -qxF 'https://h/x?a=1&b=2' "$ARGV_LOG" || { echo "FAIL: url not a single argv token"; cat "$ARGV_LOG"; exit 1; }
grep -qxF 'Custom UA/1.0' "$ARGV_LOG"        || { echo "FAIL: ua not a single argv token"; cat "$ARGV_LOG"; exit 1; }
# empty UA falls back to the browser default
grep -qxF 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36' "$ARGV_LOG" \
  || { echo "FAIL: DEFAULT_UA fallback not applied for empty UA"; cat "$ARGV_LOG"; exit 1; }
# curl flags present
grep -qxF -- '--max-time' "$ARGV_LOG" || { echo "FAIL: --max-time missing"; exit 1; }

echo "PASS"
