#!/bin/sh
# Tests lib/reveal.uc: grant generates a token, validate true within TTL,
# false after TTL, revoke deletes. Uses mock clock to test TTL boundary.

set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"

if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
    echo "SKIP test_reveal_uc (ucode missing)"
    exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REVEAL_TOKEN_PATH="$TMPDIR/reveal_token.json"

"$UCODE_BIN" -L "$UCODE_LIB_DIR" -e '
    let r = require("reveal");
    let now = 1000;
    r._set_clock_for_test(function() { return now; });

    // grant returns shape {token, expires_ts}
    let g = r.grant("alice");
    assert(g.token != null && length(g.token) === 32,
           "token must be 32 hex chars; got: " + g.token);
    assert(g.expires_ts === now + 300, "expires_ts must equal now+TTL");

    // validate true within TTL
    assert(r.validate(g.token) === true, "fresh token should validate");

    // bump clock to just-before-TTL
    now += 299;
    assert(r.validate(g.token) === true, "token at TTL-1 should still validate");

    // bump past TTL
    now += 2;   // now = 1301, issued_ts = 1000, delta = 301 > 300
    assert(r.validate(g.token) === false, "expired token should not validate");

    // revoke removes the file
    r.revoke();
    assert(r.validate(g.token) === false, "revoked token should not validate");

    // garbage tokens never validate
    assert(r.validate("garbage") === false, "garbage token rejected");
    assert(r.validate("") === false, "empty token rejected");
    assert(r.validate(null) === false, "null token rejected");

    // second grant overwrites first
    let g1 = r.grant("alice");
    let g2 = r.grant("bob");
    assert(r.validate(g1.token) === false, "first token revoked by second grant");
    assert(r.validate(g2.token) === true, "second token valid");

    print("PASS test_reveal_uc\n");
'
