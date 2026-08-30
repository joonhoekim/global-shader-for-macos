#!/usr/bin/env bash
#
# brew-nix.sh — run `brew` subcommands that need to write to Homebrew's own library,
# on a machine where nix owns Homebrew.
#
#   ./tools/brew-nix.sh style Formula/global-shader.rb
#   ./tools/brew-nix.sh install --build-from-source gs-ci/local/global-shader
#   ./tools/brew-nix.sh test gs-ci/local/global-shader
#   ./tools/brew-nix.sh                      # prints the shim path, for scripting
#
# ── What is broken ──────────────────────────────────────────────────────
# Under nix-homebrew, /opt/homebrew/Library/Homebrew is a symlink into /nix/store, which
# is read-only by design. Two things then fail, and only the first is obvious:
#
#   1. Anything that loads Homebrew's vendored gems — `brew style`, `brew test`, `brew
#      audit` — runs `bundle install` first and then stamps
#      Library/Homebrew/vendor/bundle/ruby/*/.homebrew_vendor_version. That write lands in
#      the store. The error names the store path, so this one at least explains itself:
#
#        Error: Permission denied @ rb_sysopen - /nix/store/…/.homebrew_vendor_version
#
#   2. `brew style` also wants $HOMEBREW_LIBRARY/.rubocop.yml, and nix-homebrew does not
#      link it out of the store into /opt/homebrew/Library at all. So fixing (1) alone
#      moves you to "Configuration file not found" and no further.
#
# `brew install` is unaffected — it only writes to the Cellar. It is the commands that
# treat Homebrew's own checkout as scratch space that cannot run, which is exactly the
# half of ci.yml's `formula` job that a nix user would otherwise have to push to find out
# about.
#
# ── What this does ──────────────────────────────────────────────────────
# Mirrors Library/Homebrew somewhere writable — 22M, so this is cheaper than it sounds —
# and redirects HOMEBREW_LIBRARY at the mirror. Everything else is left alone on purpose:
# HOMEBREW_PREFIX and the Cellar stay /opt/homebrew, so formulae you already have
# installed are the ones this sees, and Taps is symlinked back to the real directory so a
# tap made through the shim is a tap the normal `brew` can see too.
#
# This is a local convenience, not part of any build. CI runs stock Homebrew on a stock
# runner and needs none of it.
set -euo pipefail

BREW="$(command -v brew || true)"
[ -n "$BREW" ] || { echo "brew is not on PATH" >&2; exit 1; }

PREFIX="$("$BREW" --prefix)"
LIB="$PREFIX/Library"
REAL="$(readlink "$LIB/Homebrew" || true)"

case "$REAL" in
    /nix/store/*) ;;
    *)
        # Nothing to work around. Saying so beats silently building a mirror that only
        # drifts from the real thing.
        echo "$LIB/Homebrew is not a /nix/store symlink — your brew can write to itself." >&2
        echo "Use brew directly: brew $*" >&2
        exit 1
        ;;
esac

STORE_LIB="$(dirname "$REAL")"
MIRROR="${XDG_CACHE_HOME:-$HOME/.cache}/global-shader/brew-nix"
STAMP="$MIRROR/.store-path"
SHIM="$MIRROR/brew"

# Rebuilt when the store path changes — that is what a nix-homebrew upgrade looks like
# from here, and a mirror of the old brew would go on working while being wrong.
if [ ! -x "$SHIM" ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$REAL" ]; then
    echo "mirroring $STORE_LIB → $MIRROR" >&2
    rm -rf "$MIRROR"
    mkdir -p "$MIRROR/Library"
    cp -R "$REAL" "$MIRROR/Library/Homebrew"
    # The store copies come out read-only, which is the whole problem being solved.
    chmod -R u+w "$MIRROR/Library/Homebrew"

    # Everything else in the real Library is already outside the store and writable —
    # Taps above all. Symlink it rather than copy, so taps made through the shim and taps
    # made through the real brew are the same taps.
    for entry in "$LIB"/* "$LIB"/.[!.]*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        [ "$name" = "Homebrew" ] && continue
        ln -s "$entry" "$MIRROR/Library/$name"
    done

    # (2) above: present in the store, never linked out of it. Copied only if the real
    # Library did not already have one to symlink.
    if [ ! -e "$MIRROR/Library/.rubocop.yml" ] && [ -f "$STORE_LIB/.rubocop.yml" ]; then
        cp "$STORE_LIB/.rubocop.yml" "$MIRROR/Library/.rubocop.yml"
        chmod u+w "$MIRROR/Library/.rubocop.yml"
    fi

    # The shim is nix's own bin/brew with two paths moved. Generated rather than written
    # by hand because the rest of that file is upstream's launcher, and it changes.
    sed -e "s|^export HOMEBREW_LIBRARY=.*|export HOMEBREW_LIBRARY=\"$MIRROR/Library\"|" \
        -e "s|^export HOMEBREW_BREW_FILE=.*|export HOMEBREW_BREW_FILE=\"$SHIM\"|" \
        "$BREW" > "$SHIM"
    chmod +x "$SHIM"
    grep -q "^export HOMEBREW_LIBRARY=\"$MIRROR/Library\"$" "$SHIM" \
        || { echo "could not redirect HOMEBREW_LIBRARY in $BREW — has nix-homebrew's launcher changed?" >&2; exit 1; }
    echo "$REAL" > "$STAMP"
fi

# No arguments: hand back the path. Lets a script call it once and reuse the shim, rather
# than paying the mirror check on every brew invocation.
if [ "$#" -eq 0 ]; then
    echo "$SHIM"
    exit 0
fi

# The first run through here also does a `bundle install` into the mirror, which takes a
# minute. Every run after that is as fast as brew.
exec "$SHIM" "$@"
