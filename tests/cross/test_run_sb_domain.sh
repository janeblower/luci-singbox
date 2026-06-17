#!/bin/sh
# tests/cross/test_run_sb_domain.sh — verifies SB_DOMAIN filtering in
# tests/run.sh composes with SB_SUITE. We don't run the real suite (needs
# ucode/VM); instead we drive run.sh in a DRY-RUN mode that just prints the
# resolved test-file list, and assert membership.
set -eu
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $1" >&2; exit 1; }

# `env` is required (not a bare `VAR=val ... sh` prefix): the env-assignment
# words arrive via "$@" from variable expansion, and POSIX shells do NOT
# re-recognise an expanded word as an assignment — `SB_SUITE=backend cross`
# would be run as a command (127). `env` reparses them into the environment.
list() { SB_DRY_RUN=1 env "$@" sh tests/run.sh 2>/dev/null; }

# No SB_DOMAIN => all areas in SB_SUITE appear (backend + cross sample present).
out=$(list SB_SUITE="backend cross")
printf '%s\n' "$out" | grep -q 'tests/backend/' || fail "no backend files in unfiltered list"
printf '%s\n' "$out" | grep -q 'tests/cross/'   || fail "no cross files in unfiltered list"

# SB_DOMAIN=backend keeps tests/backend/* and tests/parity-domain files, drops
# tests/cross/* (cross => packaging domain).
out=$(list SB_SUITE="backend cross" SB_DOMAIN="backend")
printf '%s\n' "$out" | grep -q 'tests/backend/' || fail "backend files dropped under SB_DOMAIN=backend"
printf '%s\n' "$out" | grep -q 'tests/cross/'   && fail "cross files NOT dropped under SB_DOMAIN=backend"

# SB_DOMAIN=packaging keeps tests/cross/*, drops tests/backend/*.
out=$(list SB_SUITE="backend cross" SB_DOMAIN="packaging")
printf '%s\n' "$out" | grep -q 'tests/cross/'   || fail "cross files dropped under SB_DOMAIN=packaging"
printf '%s\n' "$out" | grep -q 'tests/backend/' && fail "backend files NOT dropped under SB_DOMAIN=packaging"

# Composition: SB_SUITE narrows to areas, SB_DOMAIN narrows within.
# SB_SUITE="cross" + SB_DOMAIN="backend" => empty (cross files are packaging).
out=$(list SB_SUITE="cross" SB_DOMAIN="backend")
printf '%s\n' "$out" | grep -q 'tests/cross/' && fail "SB_DOMAIN=backend should exclude all cross files"

# Multi-domain: SB_DOMAIN="backend packaging" keeps both.
out=$(list SB_SUITE="backend cross" SB_DOMAIN="backend packaging")
printf '%s\n' "$out" | grep -q 'tests/backend/' || fail "backend dropped under multi-domain"
printf '%s\n' "$out" | grep -q 'tests/cross/'   || fail "cross dropped under multi-domain"

echo "OK"
