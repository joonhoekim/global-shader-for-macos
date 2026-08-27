#!/usr/bin/env bash
#
# make-signing-cert.sh — makes one self-signed certificate to sign this app with.
#
# ── Why it is needed ─────────────────────────────────────────────────────
# Without a certificate, build.sh falls back to an ad-hoc signature (codesign -s -). The
# signature then points at nothing but the binary itself, so the code's "designated
# requirement" comes out as:
#
#     cdhash H"9fcf4e15…"
#
# When TCC (Screen Recording permission) grants access, it stores that requirement whole
# and checks it again the next time the app asks. So **every rebuild is denied** — one
# byte of difference in the binary changes the cdhash. The tccd log says:
#
#     Failed to match existing code requirement for subject
#     dev.jh.global-shader and service kTCCServiceScreenCapture
#
# The nastiest part is that macOS **does not ask again**. The entry already exists, so the
# checkbox in System Settings stays on while the app alone is quietly denied. "The
# permission is definitely on and nothing happens" is the symptom.
#
# Signed with a certificate, the requirement becomes:
#
#     identifier "dev.jh.global-shader" and certificate leaf H"…"
#
# The certificate stays put, so any number of rebuilds produce the same requirement. The
# permission is granted once.
#
# ── What this does and does not get you ──────────────────────────────────
# Apple does not vouch for this certificate, so the app cannot be handed to anyone else
# (Gatekeeper stops it). That is not the point; the point is **making the TCC grant on
# your own machine survive a rebuild**. When notarization is needed, that is an Apple
# Developer certificate.
#
#   ./tools/make-signing-cert.sh          create
#   ./tools/make-signing-cert.sh --remove  delete
#
# ── Why the name is not the app's name ───────────────────────────────────
# The default CN is "jh local codesign", not "GlobalShader". Few people have exactly one
# hand-built .app, and what this identity does is the same for every app. A separate
# identity per app only multiplies what has to be re-approved. GS_SIGN_ID overrides it.
set -euo pipefail

CN="${GS_SIGN_ID:-jh local codesign}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ "${1:-}" = "--remove" ]; then
    echo "removing: $CN"
    security delete-certificate -c "$CN" "$KEYCHAIN" 2>/dev/null \
        && echo "  certificate removed" || echo "  no such certificate"
    echo
    echo "build.sh goes back to ad-hoc signing, which means granting Screen Recording"
    echo "permission again after every rebuild:"
    echo "  tccutil reset ScreenCapture dev.jh.global-shader"
    exit 0
fi

if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "already there: $CN"
    echo "To make a new one, --remove first."
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Extensions go through a config file. The -addext flag does not work on some versions of
# the LibreSSL macOS carries, so this route, which works on both implementations, is used.
cat > "$tmp/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $CN

[ ext ]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
# This is what makes codesign recognize the certificate as something to sign with.
extendedKeyUsage     = critical,codeSigning
EOF

echo "creating the certificate: $CN"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$tmp/openssl.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

# Certificate and private key are imported separately. Bundling them into a p12 also
# works, but OpenSSL 3 and LibreSSL differ on the default encryption, which splits on
# whether -legacy is passed. Imported separately, that split does not exist.
#
# -T /usr/bin/codesign: pre-authorize codesign so it does not ask every time it uses the key.
echo "importing into the keychain"
security import "$tmp/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
security import "$tmp/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null

# Trusted for code signing only. A GUI password prompt appears once here.
# A failure does not stop anything, since signing still works — trust is the verifier's
# side of the story, and all we need is the fact that it was signed with the same certificate.
echo "marking it trusted for code signing (it asks for your password once)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem" \
    2>/dev/null && echo "  done" || echo "  skipped (signing is unaffected)"

echo
echo "→ ./build.sh now picks up this certificate on its own."
echo
echo "  The first time, Screen Recording permission has to be granted again, because"
echo "  the old grant is tied to the old signature:"
echo
echo "    tccutil reset ScreenCapture dev.jh.global-shader"
echo "    ./build.sh && open build/GlobalShader.app"
echo
echo "  After that it never asks again, however many times you rebuild."
