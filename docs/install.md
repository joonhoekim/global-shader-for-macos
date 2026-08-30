# Installing with Homebrew

*[← README](../README.md)  ·  [한국어](install.ko.md)*

```sh
brew tap joonhoekim/global-shader https://github.com/joonhoekim/global-shader-for-macos
brew install joonhoekim/global-shader/global-shader
open "$(brew --prefix global-shader)/GlobalShader.app"
```

The url is spelled out because `brew tap user/name` on its own looks for a repository
called `homebrew-name`. This one is named after what it is, not after Homebrew, so the
tap is given its address. Nothing else changes: after this, `brew upgrade global-shader`
and `brew uninstall global-shader` work under the short name.

## Why a formula and not a cask

A cask is the usual way to install a Mac app, and it is the one route that cannot work
here yet.

A cask downloads a finished `.app`, and Homebrew marks what it downloads with the
quarantine attribute. Gatekeeper then wants the app notarized, notarization wants a paid
Apple Developer account, and there is no account — the premise the whole of
[`plan/`](../plan/README.md) is written under. Self-signing does not substitute: Apple
vouching for the certificate is the entire content of the check.

A formula compiles on the machine it installs on. Nothing arrives as a downloaded app, so
nothing is quarantined, and Gatekeeper has no opinion about a binary the machine built
itself. The cost is not removed, only moved — it comes back as
[Upgrades revoke Screen Recording permission](#upgrades-revoke-screen-recording-permission),
below.

The build is the same `./build.sh` as a clone: `swiftc`, a bundle, an ad-hoc signature.
`glslang` and `spirv-cross` come in as Homebrew dependencies, so they are installed for
you.

## What lands where

| | |
|---|---|
| `$(brew --prefix global-shader)/GlobalShader.app` | the app — this is what holds Screen Recording permission |
| `$(brew --prefix)/bin/global-shader` | the command line, a symlink into the bundle |
| `$(brew --prefix global-shader)/share/global-shader/shaders` | the shaders it ships with |
| `$(brew --prefix global-shader)/libexec/make-signing-cert.sh` | the certificate script, for the section below |

A formula cannot put anything in `/Applications` — that is a cask's job — so the app sits
in the prefix. To reach it from Finder and Spotlight:

```sh
ln -sfn "$(brew --prefix global-shader)/GlobalShader.app" /Applications/GlobalShader.app
```

Start it from the bundle, not from the command line. A bare binary borrows the Screen
Recording permission of whatever launched it, which is your terminal; the bundle holds the
grant under its own name. The reason is in
[Screen Recording permission](permissions.md). Once it is running, the `global-shader`
command talks to it over the control socket, and that needs no permission of its own:

```sh
open "$(brew --prefix global-shader)/GlobalShader.app"
global-shader "$(brew --prefix global-shader)/share/global-shader/shaders/crt/crt.frag"
global-shader --set CURVE 0.22
global-shader --stop
```

## Upgrades revoke Screen Recording permission

This is the price of the formula route, and it is worth knowing before it happens.

Every install builds the app fresh, and that build is ad-hoc signed — its designated
requirement is a bare `cdhash`. TCC stored the old cdhash when you granted the permission
and matches against it. A new build is a new hash, so the grant no longer applies, and
**macOS does not ask again**: the checkbox in System Settings stays on while capture
quietly stops. After every `brew upgrade global-shader`:

```sh
tccutil reset ScreenCapture dev.jh.global-shader
open "$(brew --prefix global-shader)/GlobalShader.app"     # allow when it asks
```

### Why the certificate cannot do it from inside

A clone gets out of this by signing with a certificate that stays put
([Screen Recording permission](permissions.md)). Through Homebrew that route is closed,
and it is worth saying exactly why, because "just make the certificate first" looks like
it should work:

| | |
|---|---|
| The build's `HOME` is a throwaway | Homebrew points `HOME` at a `.brew_home` inside the build directory. The keychain search list is read out of `HOME`, so `security` sees only the system keychain — no login keychain, no identity |
| The sandbox denies `~/Library/Keychains` | Naming the keychain outright does not help either. Homebrew's build sandbox carries an explicit deny for that path, alongside `.ssh`, `.gnupg` and the rest |
| There is no opt-out | `HOMEBREW_NO_SANDBOX` was removed; as of brew 6 only Linux and cask sandboxing can be switched off. A formula build is sandboxed, always |

None of that is worth fighting. The sandbox is right to deny it.

### Signing it yourself, from outside

What the sandbox blocks is the *build* reaching your keychain. Your own shell is under no
such restriction, and the installed bundle is writable, so the signature can simply be
replaced afterwards. Make the identity once:

```sh
"$(brew --prefix global-shader)/libexec/make-signing-cert.sh"
```

and then, after each upgrade:

```sh
codesign --force --sign "jh local codesign" "$(brew --prefix global-shader)/GlobalShader.app"
```

The requirement becomes `identifier "dev.jh.global-shader" and certificate leaf H"…"` —
the same value every time, because the certificate does not change. TCC keeps matching,
so the permission survives the upgrade and nothing is asked. It is the same signature a
clone would have produced; only the moment it is applied differs.

If you would rather not re-sign by hand at all, build from a clone: there the certificate
is picked up by `./build.sh` itself, and an upgrade is a `git pull` away.

## Until the first tagged release

There is no `v*` tag yet, so the formula carries no stable url — only `head`. Homebrew
handles that: with no stable version, `brew install` builds from `main`.

The one difference is upgrading. `brew upgrade` compares versions and a head install has
none to compare, so it needs to be told to look:

```sh
brew upgrade --fetch-HEAD global-shader
```

When a tag exists, [`tools/update-formula.sh`](../tools/update-formula.sh) writes the
tarball url and its sha256 into the formula, and plain `brew upgrade` starts working.

## Uninstalling

```sh
brew uninstall global-shader
brew untap joonhoekim/global-shader
rm -f /Applications/GlobalShader.app             # if the symlink was made
tccutil reset ScreenCapture dev.jh.global-shader
```

Settings and profiles are not Homebrew's and stay behind, in
`~/.config/global-shader/`.

## What changes with an Apple Developer account

The cask becomes possible: `tools/release.sh` already builds the zip and leaves the
signing section empty, and two lines — `codesign --options runtime` and
`notarytool submit` — fill it. A cask would then install a notarized app into
`/Applications` with no permission caveat, because a notarized signature is stable across
versions and TCC keeps the grant.

The formula does not have to go away when that happens. It is the route for anyone who
would rather build from source than trust a download, and it is what keeps the tap
working today.
