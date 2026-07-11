#!/bin/sh
# Publish a freshly-built apk feed tree (scripts/build-feed.sh output) to the
# gh-pages branch, DELETING the stale package versions this feed owns while
# leaving sibling subtrees untouched.
#
# Why this exists instead of peaceiris/actions-gh-pages keep_files:true —
# keep_files merges onto gh-pages and NEVER deletes. build-feed.sh regenerates
# packages.adb + index.md (overwritten by name on every deploy), but each
# release is a NEW apk filename (<name>-0.0.0-r<count>.apk), so every past
# version's .apk piled up in gh-pages forever. We still cannot do a full-replace:
# the sing-box-extended core feeds (.github/workflows/sing-box-extended.yml) live
# as siblings at <ver>/<arch>/sing-box/ and are published independently with
# their own keep_files. So this script clones gh-pages, wipes only the
# directories THIS feed owns (default name: luci-singbox, i.e.
# <ver>/<arch>/luci-singbox/), overlays the freshly built tree (current version
# only), and pushes — so old versions vanish while the sing-box/ subtree (and any
# other content) survives, same coexistence guarantee keep_files gave us.
#
# Usage: publish-feed.sh <public_dir>
#
# Env:
#   FEED_GIT_REMOTE   git URL/path to clone gh-pages from and push to (REQUIRED).
#                     In CI this embeds the token:
#                     https://x-access-token:<TOKEN>@github.com/<owner>/<repo>.git
#   FEED_BRANCH       branch to publish (default: gh-pages)
#   FEED_OWNED_DIR    directory name this feed owns, wiped before overlay
#                     (default: luci-singbox)
#   FEED_COMMIT_MSG   commit subject (default: "deploy feed")
#   FEED_WORK         working clone dir (default: a fresh mktemp dir)
#   FEED_NO_PUSH      if non-empty: commit into FEED_WORK but do not push
#                     (used by the regression test to inspect the merged tree)
set -eu

PUB="${1:?usage: publish-feed.sh <public_dir>}"
: "${FEED_GIT_REMOTE:?FEED_GIT_REMOTE required (gh-pages git remote)}"
BRANCH="${FEED_BRANCH:-gh-pages}"
OWNED="${FEED_OWNED_DIR:-luci-singbox}"
MSG="${FEED_COMMIT_MSG:-deploy feed}"

[ -d "$PUB" ] || { echo "public dir not found: $PUB" >&2; exit 1; }
# Absolute path — we cd into / operate from the working clone below.
PUB="$(cd -- "$PUB" && pwd)"

WORK="${FEED_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/publish-feed.XXXXXX")}"

# Single attempt, no retry loop. The two workflows that publish this branch
# (pages.yml and sing-box-extended.yml) both sit in `concurrency: group: pages`,
# so GitHub already serialises them — the re-clone/jitter/backoff loop guarded a
# race that cannot happen. A non-fast-forward now means something OUTSIDE CI wrote
# to the branch, which should fail loudly and be re-run, not be papered over.
rm -rf "$WORK"
git clone --quiet --depth 1 --branch "$BRANCH" "$FEED_GIT_REMOTE" "$WORK"

# Wipe every directory THIS feed owns so stale versioned .apk files do not
# accumulate. -prune stops descent into the matched dir; rm removes it whole.
# Sibling subtrees (e.g. <ver>/<arch>/sing-box/) are never named OWNED, so they
# are left exactly as the other workflow published them.
find "$WORK" -type d -name "$OWNED" -prune -exec rm -rf {} +

# Overlay the freshly built tree: current-version apks + freshly regenerated
# packages.adb / index.md / root files. cp -a keeps build-feed.sh's layout and
# never touches "$WORK/.git" (public has no .git of its own).
cp -a "$PUB"/. "$WORK"/

git -C "$WORK" \
  -c user.name='github-actions[bot]' \
  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  add -A
if git -C "$WORK" diff --cached --quiet; then
  echo "feed already up to date -> nothing to commit"
  exit 0
fi
git -C "$WORK" \
  -c user.name='github-actions[bot]' \
  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit --quiet -m "$MSG"

if [ -n "${FEED_NO_PUSH:-}" ]; then
  echo "FEED_NO_PUSH set -> committed to $WORK, not pushing"
  exit 0
fi

push_err="$WORK/.push_err"
if git -C "$WORK" push origin "HEAD:$BRANCH" 2>"$push_err"; then
  rm -f "$push_err"
  echo "published feed to $BRANCH"
  exit 0
fi

echo "push to $BRANCH failed:" >&2
cat "$push_err" >&2
rm -f "$push_err"
exit 1
