#!/bin/sh
# scripts/regen-po.sh
# Regenerate the gettext template from JS sources and msgmerge into po/ru.
# Run this whenever new _('...') strings are added to the UI.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS_DIR="$ROOT/luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui"
PO_DIR="$ROOT/luci-singbox-ui/po"
POT="$PO_DIR/templates/luci-singbox-ui.pot"
RU="$PO_DIR/ru/luci-singbox-ui.po"

mkdir -p "$PO_DIR/templates"

find "$JS_DIR" -name '*.js' -print0 \
    | xargs -0 xgettext \
        --language=JavaScript \
        --keyword=_ \
        --from-code=UTF-8 \
        --package-name=luci-singbox-ui \
        -o "$POT"

if [ -f "$RU" ]; then
    msgmerge --update --backup=none --no-fuzzy-matching "$RU" "$POT"
else
    echo "po/ru/luci-singbox-ui.po missing — initialize manually" >&2
    exit 1
fi

echo "Regenerated $POT and updated $RU."
echo "Translate any new msgid in $RU (currently untranslated entries have empty msgstr \"\")."
