#!/usr/bin/env bash
#
# release.sh — builds one distributable bundle.
#
# ── What this script builds right now is something nobody else can open ──
# There is no paid Apple Developer account, so it cannot be notarized. Downloading an
# un-notarized .app gets you a Gatekeeper "is damaged" refusal. A self-signed certificate
# does not solve that — as the header of tools/make-signing-cert.sh says, that is for
# **making the TCC grant on this machine survive a rebuild**, not for distribution.
#
# The script exists now anyway, because it reduces the work on the day an account appears
# to "fill in two lines in the signing section below". Everything before that — the
# universal build, the version check, how the zip is made, the sha256 — has nothing to do
# with the account and can be settled now.
#
#   ./tools/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/GlobalShader.app"
DIST="build/dist"
ZIP="$DIST/GlobalShader-$VERSION.zip"

echo "── build ─────────────────────────────────────────────────────────────"
# A release is always universal. The Intel build has never actually been run, but shipping
# it and stating what was verified beats withholding something that builds.
GS_ARCHS="arm64 x86_64" GS_BUILD_NUMBER="${GS_BUILD_NUMBER:-1}" ./build.sh

# Check that the version given actually got baked in. If the premise that VERSION is the
# single source breaks, the cask's version and the app's diverge, and brew upgrade will
# say "up to date" forever.
GOT="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
[ "$GOT" = "$VERSION" ] || { echo "bundle version is $GOT but VERSION says $VERSION" >&2; exit 1; }

echo
echo "── signing ───────────────────────────────────────────────────────────"
# ┌───────────────────────────────────────────────────────────────────────┐
# │ With a paid account, these two stages replace build.sh's signature.   │
# │                                                                       │
# │   codesign --force --options runtime --timestamp \                    │
# │            --sign "Developer ID Application: <name> (<TEAMID>)" \     │
# │            "$APP"                                                     │
# │                                                                       │
# │   ditto -c -k --keepParent "$APP" "$ZIP"                              │
# │   xcrun notarytool submit "$ZIP" --keychain-profile <profile> --wait  │
# │   xcrun stapler staple "$APP"      # then remake the zip              │
# │                                                                       │
# │ Without --options runtime (hardened runtime), notarization refuses.   │
# │ If the tools go into Contents/Helpers, every Mach-O inside the bundle │
# │ has to be signed **from the inside out** before the .app itself.      │
# │                                                                       │
# │ The designated requirement then becomes this, and Screen Recording    │
# │ permission survives a version bump:                                   │
# │   identifier "dev.jh.global-shader" and anchor apple generic and       │
# │     certificate leaf[subject.OU] = <TEAMID>                           │
# └───────────────────────────────────────────────────────────────────────┘
REQ="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
echo "requirement  ${REQ:-(none)}"
case "$REQ" in
    *"anchor apple generic"*) NOTARIZABLE=1 ;;
    *) NOTARIZABLE= ;;
esac

echo
echo "── packaging ─────────────────────────────────────────────────────────"
rm -rf "$DIST"
mkdir -p "$DIST"
# ditto, because zip(1) can drop resource forks and extended attributes and break the signature.
ditto -c -k --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP" | cut -f1)"

echo "→ $ZIP  ($SIZE)"
echo "  sha256  $SHA"
echo
echo "ready to paste into the cask:"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA\""
echo
# The formula is a different route and takes nothing from this zip. It builds from the
# tag's source tarball, whose sha256 is not this one — hence a script rather than a
# copy-paste of the value above.
echo "the formula is separate — it builds from the tag's source tarball:"
echo "  ./tools/update-formula.sh v$VERSION"

if [ -z "$NOTARIZABLE" ]; then
    cat <<GSEOF

⚠ This zip **must not be handed to anyone.**

  It is not notarized, so the downloader's macOS refuses to open it. The symptom is
  "damaged and can't be opened", and since nothing is actually damaged — the signature
  is simply missing — nobody finds the cause.

  What is needed before uploading:
    1. Apple Developer Program (\$99/year)
    2. A Developer ID Application certificate
    3. Fill in the "signing" section of this script

  There is exactly one thing this zip is good for right now — putting it in
  /Applications on this machine and trying it.
GSEOF
fi
