# shellcheck shell=sh
# tests/lib/domain_classify.sh — pure path->domain classifier for the CI
# `changes` job and tests/cross/test_changes_domains.sh. Directory-based
# 4-domain model. Reads a newline-separated file list on stdin, prints four
# lines in a FIXED order: bbolt= / backend= / ui= / packaging= (true|false).
#
# Trigger regexes (ERE, matched with `grep -qE`):
#   bbolt:     ^bbolt-client/
#   backend:   ^(singbox-ui/|tests/backend/|tests/parity/)
#   ui:        ^(luci-app-singbox-ui/|tests/ui/|tests/browser/)
#   packaging: ^(scripts/|install\.sh|feed/|.*/Makefile|tests/cross/)
#   shared (=> all four true): ^(tests/lib/|tests/run|tests/docker/|tests/browser-container/|\.github/)
#   EXCEPT .github/workflows/sing-box-extended.yml — a standalone workflow with
#   its own dispatch/schedule trigger that checks out the cores/sing-box-extended
#   branch. It is NOT part of the luci package build/test, so a change to ONLY
#   that file must not fan out to any domain.
sb_classify_domains() {
	_in=$(cat)
	_bbolt=false; _backend=false; _ui=false; _packaging=false
	# .github is shared EXCEPT the standalone sing-box-extended workflow: github
	# changes fan out only if at least one changed github file is NOT that file.
	_github_shared=false
	if printf '%s\n' "$_in" | grep -E '^\.github/' \
		| grep -qvE '^\.github/workflows/sing-box-extended\.yml$'; then
		_github_shared=true
	fi
	# shared fan-out first: any shared path turns on everything and we are done.
	if [ "$_github_shared" = true ] || printf '%s\n' "$_in" | grep -qE '^(tests/lib/|tests/run|tests/docker/|tests/browser-container/)'; then
		_bbolt=true; _backend=true; _ui=true; _packaging=true
	else
		printf '%s\n' "$_in" | grep -qE '^bbolt-client/' && _bbolt=true
		printf '%s\n' "$_in" | grep -qE '^(singbox-ui/|tests/backend/|tests/parity/)' && _backend=true
		printf '%s\n' "$_in" | grep -qE '^(luci-app-singbox-ui/|tests/ui/|tests/browser/)' && _ui=true
		printf '%s\n' "$_in" | grep -qE '^(scripts/|install\.sh|feed/|.*/Makefile|tests/cross/)' && _packaging=true
	fi
	printf 'bbolt=%s\n'     "$_bbolt"
	printf 'backend=%s\n'   "$_backend"
	printf 'ui=%s\n'        "$_ui"
	printf 'packaging=%s\n' "$_packaging"
}
