# Rebuilding silently cuts off Screen Recording permission

*[← README](../README.md)  ·  [한국어](permissions.ko.md)*

**This one cost real time.** The symptom is "the permission is clearly checked in
System Settings and nothing happens."

When `build.sh` uses an ad-hoc signature (`codesign -s -`), the designated
requirement becomes:

```
designated => cdhash H"6d3a31a07290c00701e45474884eb5b0138c2657"
```

TCC stores that entire requirement when it grants permission and matches against
it next time. So **a one-byte difference in the binary is a denial.** It shows up
verbatim in the `tccd` log:

```
Failed to match existing code requirement for subject
dev.jh.global-shader and service kTCCServiceScreenCapture
```

The nasty part is that macOS **does not ask again.** The entry already exists, so
the checkbox stays checked and only the app is denied.

## Why it works from a terminal and not from Finder

Same binary, different outcome.

| How it was started | Identity | Result |
|---|---|---|
| `open` · Finder · launchd | `dev.jh.global-shader` | denied when the cdhash does not match |
| `./build/global-shader` | no bundle ID → **the terminal** | passes on the terminal's permission |

`build/global-shader` is a symlink, so `Bundle.main` does not find the `.app` and
the permission attaches to the parent process. So it working from a terminal is
not the app having permission — it is **borrowing the terminal's.** The
`bundle ''` in the log is the tell.

## The fix

Making a certificate once removes the round trip.

```sh
./tools/make-signing-cert.sh
tccutil reset ScreenCapture dev.jh.global-shader
./build.sh && open build/GlobalShader.app     # asks again → allow
```

The certificate is not named after this app; it is a shared identity
(`jh local codesign`). Hand-built `.app`s are rarely just one, and what this
identity does is no different per app — keeping one per app only multiplies the
combinations you have to re-approve. `GS_SIGN_ID` overrides it.

The requirement becomes `identifier "…" and certificate leaf H"…"`, which is the
same no matter how many times you rebuild. `build.sh` uses the certificate if it
is there and falls back to ad-hoc if not, printing this guidance. It also shows
what actually got baked in on every build.

To live without a certificate: `tccutil reset` and allow again after every
rebuild.

## The app tells you itself

There is a reason this failure is so quiet. The window is shown **after the first
frame arrives** (see [Safety nets](architecture.md)), so when capture does not
attach there is no
window, no error, and no visible change on screen. And when started from Finder,
stderr goes nowhere.

So if no frame arrives within 4 seconds, the menu bar title becomes `◲⚠` and the
menu carries the reason and the fix. It is also visible in `capture` in
`--status`:

```sh
global-shader --status
  {"chain":[…],"capture":"Screen Recording permission was denied",…,"fps":0.0}
```
