#!/bin/sh
# tests/test_gen_manifest_override.sh
# Black-box behavioral regression for S5-8: gen-manifest.sh must match
# override rows by EXACT source path, never as a regex. A path with a
# metacharacter (e.g. `a.b`) must not steal the override of a different
# sibling (`aXb`) and vice-versa.
#
# We drive the REAL script against a throwaway tree via the PKG/OUT/OVERRIDES
# env hooks, so this asserts the matching SEMANTICS (which row is emitted),
# not the implementation text.
set -e
cd "$(dirname "$0")/../.."

td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT

pkg="$td/pkg"
mkdir -p "$pkg/root/etc/config"
# Two sibling files differing only by the char a regex '.' would conflate.
: > "$pkg/root/etc/config/a.b"
: > "$pkg/root/etc/config/aXb"

# Override targets ONLY a.b. As a REGEX, '^root/etc/config/a.b<TAB>' also
# matches 'root/etc/config/aXb' (the bug). As a fixed string it must not.
ovr="$td/overrides.txt"
printf 'root/etc/config/a.b\tHIT_AB\tdata\n' > "$ovr"

out="$td/manifest.txt"
PKG="$pkg" OUT="$out" OVERRIDES="$ovr" sh scripts/gen-manifest.sh >/dev/null 2>&1

# a.b MUST take the override (its dst column is the sentinel HIT_AB).
grep -q '^root/etc/config/a\.b	HIT_AB	data$' "$out" \
	|| { echo "FAIL: a.b did not receive its exact override"; echo "--- manifest:"; cat "$out"; exit 1; }

# aXb MUST NOT have been hit by a.b's override — it must keep its generated
# dst (etc/config/aXb, mode conf) and never show the HIT_AB sentinel.
grep -q '^root/etc/config/aXb	HIT_AB' "$out" \
	&& { echo "FAIL: aXb wrongly matched a.b's override (regex false-match)"; cat "$out"; exit 1; }
grep -q '^root/etc/config/aXb	etc/config/aXb	conf$' "$out" \
	|| { echo "FAIL: aXb missing its own generated row"; echo "--- manifest:"; cat "$out"; exit 1; }

echo "PASS: gen-manifest matches override src as an exact fixed string"
