#!/bin/bash
# tools/release.sh — выпуск версии (5 окт): файлы тега v<VERSION> dev-репо →
# публичный jeeruff/jf_tracker-release (коммит «jf_tracker X», тег vX),
# index.xml для ReaPack, zip и READ ME FIRST для itch.io.
#   tools/release.sh          — всё локально, без push
#   tools/release.sh --push   — и отправить релиз-репо (main + тег)
# Перед этим: поднять V.VERSION, закоммитить, git tag v<VERSION>.
set -euo pipefail
DEV="$(cd "$(dirname "$0")/.." && pwd)"
REL="${JF_RELEASE_DIR:-$HOME/code/reascript/jf_tracker-release}"
ITCH="${JF_ITCH_DIR:-$REL/../jf_tracker-itch}"
V=$(grep -o "V.VERSION = '[^']*'" "$DEV/jf_tracker_version.lua" | cut -d"'" -f2)
TAG="v$V"

git -C "$DEV" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "dev repo: no tag $TAG"; exit 1; }
[ -d "$REL/.git" ] || { echo "no release repo at $REL"; exit 1; }
if git -C "$REL" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "$TAG is already released"; exit 1; fi

# дерево релиза заново из тега: всё, кроме .git и index.xml
find "$REL" -mindepth 1 -maxdepth 1 ! -name .git ! -name index.xml -exec rm -rf {} +
python3 "$DEV/tools/make_index.py" --export "$TAG" "$REL"
git -C "$REL" add -A
git -C "$REL" commit -qm "jf_tracker $V"
git -C "$REL" tag "$TAG"
python3 "$DEV/tools/make_index.py" --index "$REL"
git -C "$REL" add index.xml
git -C "$REL" commit -qm "index: $TAG"

# itch.io: zip того же содержимого + READ ME FIRST
mkdir -p "$ITCH"
rm -f "$ITCH"/jf_tracker-*.zip
( cd "$REL" && git archive --format=zip --prefix=jf_tracker/ -o "$ITCH/jf_tracker-$V.zip" "$TAG" )
cat > "$ITCH/READ ME FIRST.txt" <<EOF
jf_tracker $V - a tracker core for REAPER with modules around it: Vim keys, built like Emacs. Free to use, PolyForm Shield 1.0.0 (no competing products).

INSTALL
Unzip jf_tracker-$V.zip. The README inside explains where the files go:
the jf_tracker folder into REAPER's Scripts folder, effects/ into Effects,
then Actions - Load ReaScript - jf_tracker.lua.
New versions are posted on this itch.io page.

Needs REAPER 7, SWS and js_ReaScriptAPI (both through ReaPack). Tested on macOS.

If it makes you as happy as it makes me: https://ko-fi.com/jeeruff
EOF
echo "released $TAG locally: $REL, itch files in $ITCH"

if [ "${1:-}" = "--push" ]; then
  git -C "$REL" push origin main "$TAG"
  echo "pushed $TAG"
fi
