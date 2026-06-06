#!/bin/sh
# tests/test_po_coverage.sh
# Enforce that po/ru is roughly in sync with JS _('...') sources.
# - Number of msgid entries in po should be within 5 of unique _('...') in JS.
# - At most 5 entries may be untranslated (empty msgstr "").
set -e
cd "$(dirname "$0")/.."

JS_DIR="luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui"
PO="luci-app-singbox-ui/po/ru/luci-app-singbox-ui.po"

# Count unique _('...') strings in JS (single- and double-quoted).
js_count=$(grep -rho "_('[^']*')\|_(\"[^\"]*\")" "$JS_DIR" \
    | sort -u | wc -l)

# Count msgid in po (excluding empty header msgid).
po_count=$(grep -c '^msgid ' "$PO")
po_count=$((po_count - 1))  # header msgid ""

# Count untranslated msgstr "" (excluding header AND excluding multi-line
# msgstr where the following line is a continuation string "...").
# Awk reads the file: when it sees `msgstr ""`, it peeks at the next line —
# if that next line starts with `"`, the entry is actually translated via
# continuation lines and does not count as untranslated. The very first
# `msgid ""`/`msgstr ""` pair (po header) also uses continuation, so the
# awk filter naturally excludes it.
untrans=$(awk '
    /^msgstr ""$/ {
        getline next_line
        if (next_line !~ /^"/) print
        next
    }
' "$PO" | wc -l)

echo "JS unique _('...'): $js_count"
echo "po msgid:          $po_count"
echo "po untranslated:   $untrans"

diff=$((js_count - po_count))
[ $diff -lt 0 ] && diff=$((0 - diff))

if [ "$diff" -gt 5 ]; then
    echo "FAIL: |JS - po| diff > 5 (diff=$diff). Run scripts/regen-po.sh then translate."
    exit 1
fi

if [ "$untrans" -gt 5 ]; then
    echo "FAIL: $untrans untranslated msgstr in po/ru (max allowed: 5)."
    exit 1
fi

echo "PASS: po coverage"
