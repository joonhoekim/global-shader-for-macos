#!/usr/bin/env bash
#
# update-formula.sh — writes the stable url and sha256 into the Homebrew formula.
#
# ── Why the formula ships without them ───────────────────────────────────
# A source formula needs a tarball and its sha256, and neither exists until a tag is
# pushed and GitHub has generated the archive. Until then Formula/global-shader.rb carries
# only a `head`, which is a complete formula in itself — with no stable url Homebrew
# builds from main, so `brew install` works from the day the tap goes up.
#
# On the day of a release, this fills the gap between the `stable:begin` and `stable:end`
# markers. It is the only thing that writes those two lines; editing them by hand is how
# the sha256 and the tarball drift apart.
#
#   ./tools/update-formula.sh v0.1.0             after the tag is pushed
#   ./tools/update-formula.sh file:///tmp/x.tgz  a local tarball — this is what CI does,
#                                                to install the checkout in front of it
#
# A url passed by hand has to carry the version in its file name — Homebrew reads the
# version out of it, and rejects the formula outright ("invalid attribute: version (nil)")
# when it cannot. The tag route is safe by construction: GitHub's archive url ends in
# v0.1.0.tar.gz.
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="https://github.com/joonhoekim/global-shader-for-macos"
ARG="${1:-}"
FORMULA="${2:-Formula/global-shader.rb}"

if [ -z "$ARG" ]; then
    echo "usage: tools/update-formula.sh <v-tag|url> [formula]" >&2
    exit 2
fi

case "$ARG" in
    v*)
        # A tag that disagrees with VERSION splits what brew calls the version from what
        # the app says it is, and then `brew upgrade` says "up to date" forever. The same
        # check the release workflow makes, made here too, because this is the other door
        # into the same mistake.
        want="$(tr -d '[:space:]' < VERSION)"
        if [ "${ARG#v}" != "$want" ]; then
            echo "tag $ARG does not match VERSION ($want)" >&2
            exit 1
        fi
        URL="$REPO/archive/refs/tags/$ARG.tar.gz"
        ;;
    *://*) URL="$ARG" ;;
    *)
        echo "expected a v* tag or a url, got: $ARG" >&2
        exit 2
        ;;
esac

grep -q "stable:begin" "$FORMULA" && grep -q "stable:end" "$FORMULA" || {
    echo "$FORMULA has no stable:begin / stable:end markers" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Downloaded rather than trusted: the sha256 has to come from the same bytes brew will
# fetch. curl reads file:// too, which is what makes the CI route the same code path.
echo "url     $URL"
curl -fsSL "$URL" -o "$tmp/src.tar.gz"
SHA="$(shasum -a 256 "$tmp/src.tar.gz" | cut -d' ' -f1)"
echo "sha256  $SHA"

# Everything between the markers is replaced. The lines that explain "empty until the
# first tag" go with it, which is correct — they stop being true here.
awk -v url="$URL" -v sha="$SHA" '
    /stable:begin/ { print; print "  url \"" url "\""; print "  sha256 \"" sha "\""; skip = 1; next }
    /stable:end/   { skip = 0 }
    !skip
' "$FORMULA" > "$tmp/out.rb"

if command -v ruby >/dev/null 2>&1; then
    ruby -c "$tmp/out.rb" >/dev/null
fi
mv "$tmp/out.rb" "$FORMULA"

echo
echo "→ $FORMULA"
sed -n '/stable:begin/,/stable:end/p' "$FORMULA"
