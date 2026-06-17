#!/bin/sh
# scripts/regen-po.sh
# Regenerate the gettext template from JS sources and msgmerge into po/ru.
# Run this whenever new _('...') strings are added to the UI.
#
# Determinism (audit 12.1): the output must be byte-identical no matter who
# runs this or where the repo is checked out. Three sources of churn are
# pinned:
#   1. `#:` location comments — xgettext is run from inside the package dir
#      with repo-relative source paths, so comments read
#      `htdocs/.../foo.js:NN` instead of `/home/<someone>/<reponame>/...`.
#   2. ordering — `--sort-output` emits entries sorted by msgid.
#   3. POT-Creation-Date — xgettext stamps the current time into the header
#      on every run; we rewrite it to a fixed date so regeneration is a no-op
#      diff when no strings changed (LuCI upstream pins it the same way).
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Three-way split: the LuCI frontend (htdocs JS + po/) lives in
# luci-app-singbox-ui/. The translation DOMAIN/basename stays luci-singbox-ui.
PKG_DIR="$ROOT/luci-app-singbox-ui"
# Path of the JS source tree *relative to PKG_DIR* — xgettext is invoked with
# cwd=PKG_DIR so the emitted `#:` comments stay repo-relative and portable.
JS_REL="htdocs/luci-static/resources/view/singbox-ui"
PO_DIR="$PKG_DIR/po"
POT="$PO_DIR/templates/luci-singbox-ui.pot"
RU="$PO_DIR/ru/luci-singbox-ui.po"

# Fixed creation date — keep stable so a no-string-change regen is a no-op.
POT_CREATION_DATE="2026-06-12 00:00+0000"

mkdir -p "$PO_DIR/templates"

# Run from the package dir so `find`/xgettext see relative paths and the
# `#:` comments are recorded relative to the package root (portable across
# machines and across the historical repo rename luci-singbox→luci-app-sing-box).
( cd "$PKG_DIR" && \
  find "$JS_REL" -name '*.js' -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 xgettext \
        --language=JavaScript \
        --keyword=_ \
        --from-code=UTF-8 \
        --package-name=luci-singbox-ui \
        --sort-output \
        -o "$POT" )

# Pin the timestamp so the header doesn't churn on every run.
sed -i "s/^\"POT-Creation-Date: .*\"$/\"POT-Creation-Date: $POT_CREATION_DATE\\\\n\"/" "$POT"

if [ -f "$RU" ]; then
    msgmerge --update --backup=none --no-fuzzy-matching --sort-output "$RU" "$POT"
    # msgmerge copies the template's POT-Creation-Date into the .po header;
    # re-pin it there too so the committed .po is equally stable.
    sed -i "s/^\"POT-Creation-Date: .*\"$/\"POT-Creation-Date: $POT_CREATION_DATE\\\\n\"/" "$RU"
else
    echo "po/ru/luci-singbox-ui.po missing — initialize manually" >&2
    exit 1
fi

echo "Regenerated $POT and updated $RU."
echo "Translate any new msgid in $RU (currently untranslated entries have empty msgstr \"\")."
