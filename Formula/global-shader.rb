# global-shader — this repo doubles as its own Homebrew tap.
#
#   brew tap joonhoekim/global-shader https://github.com/joonhoekim/global-shader-for-macos
#   brew install joonhoekim/global-shader/global-shader
#
# ── Why a formula and not a cask ─────────────────────────────────────────
# A cask downloads a finished .app, and Homebrew puts the quarantine attribute on what it
# downloads. Gatekeeper then refuses anything that is not notarized, and notarization
# needs a paid Apple Developer account — the premise plan/README.md is written under.
#
# A formula compiles on the machine it installs on. Nothing is downloaded as an app, so
# nothing is quarantined, and no account is involved. The cost is moved rather than
# removed: the build is ad-hoc signed, so its signature changes with every install and the
# Screen Recording grant has to be given again after an upgrade. That is what `caveats`
# below is about, and docs/install.md says the same at length.
#
# ── No bottles ───────────────────────────────────────────────────────────
# Do not build bottles for this. A bottle is relocated when it is poured, which rewrites
# the binary and breaks the signature TCC stored the grant against — the exact failure the
# caveats warn about, except with nothing on screen to explain it.
class GlobalShader < Formula
  desc "Hyprland's decoration:screen_shader, for macOS"
  homepage "https://github.com/joonhoekim/global-shader-for-macos"
  # stable:begin — written by tools/update-formula.sh; do not edit by hand.
  # Empty until the first v* tag exists. With no stable url this is a head-only formula,
  # and `brew install` builds from main, which is exactly what is wanted in the meantime.
  # stable:end
  license "MIT"
  head "https://github.com/joonhoekim/global-shader-for-macos.git", branch: "main"

  # Both shader tools are run time dependencies, not build time ones: the app shells out
  # to them every time it translates a .frag, and that happens while it runs, not here.
  # Ventura is LSMinimumSystemVersion in build.sh — ScreenCaptureKit lands in 12.3, but
  # 13.0 is the oldest this is built against.
  #
  # `macos:` sits between the two because `brew style` sorts depends_on by name.
  depends_on "glslang"
  depends_on macos: :ventura
  depends_on "spirv-cross"

  def install
    # The two tool paths are baked into the binary (build.sh, reason 2). opt_bin, not the
    # Cellar path `command -v` finds on its own: opt/ still points at glslang after
    # `brew upgrade glslang`, the versioned Cellar path is gone.
    #
    # The compiler has gone under two names across glslang's own releases, so take
    # whichever this one installed.
    glslang_bin = Formula["glslang"].opt_bin
    glslang = %w[glslang glslangValidator].map { |name| glslang_bin/name }.find(&:exist?)
    odie "no glslang compiler in #{glslang_bin}" if glslang.nil?

    ENV["GS_GLSLANG"] = glslang.to_s
    ENV["GS_SPIRV_CROSS"] = (Formula["spirv-cross"].opt_bin/"spirv-cross").to_s
    # One architecture. This is built on the machine it will run on; the universal build
    # exists for the release zip, which is a different route entirely.
    ENV["GS_ARCHS"] = Hardware::CPU.arm? ? "arm64" : "x86_64"

    # This comes out ad-hoc signed and there is no way around it from in here. Homebrew
    # builds inside a sandbox that denies reading ~/Library/Keychains, and gives the build
    # a throwaway HOME besides, so build.sh cannot see a signing certificate even when one
    # exists and even when it is named outright. Since brew 6 the sandbox has no opt-out.
    # What that costs, and the one way around it (re-sign the installed bundle from your
    # own shell, where the keychain is reachable), is in `caveats`.
    system "./build.sh"

    # The .app, not the bare binary. TCC attaches Screen Recording permission to a bundle
    # identity, and a loose executable borrows the permission of whatever launched it —
    # docs/permissions.md. The symlink in bin is for driving an instance that is already
    # up (--set, --stop, --status), which needs no permission of its own.
    prefix.install "build/GlobalShader.app"
    bin.install_symlink prefix/"GlobalShader.app/Contents/MacOS/global-shader"
    pkgshare.install "shaders"
    # Standalone — it makes one self-signed identity and touches nothing in this repo. It
    # is installed because the caveats point at it as the way out of re-granting the
    # permission on every upgrade.
    libexec.install "tools/make-signing-cert.sh"
    doc.install "README.md", "README.ko.md", "docs"
  end

  def caveats
    <<~EOS
      Start it from the bundle. That is what puts Screen Recording permission on the app
      instead of on your terminal:

        open #{opt_prefix}/GlobalShader.app

      To reach it from Finder and Spotlight:

        ln -sfn #{opt_prefix}/GlobalShader.app /Applications/GlobalShader.app

      The shaders it came with are in #{opt_pkgshare}/shaders.

      Every upgrade silently revokes that permission. A Homebrew build cannot reach your
      keychain, so the app is ad-hoc signed and its signature changes with each build;
      macOS matches the grant against the old signature and does not ask again, so the
      checkbox stays on while capture stops. After each upgrade:

        tccutil reset ScreenCapture dev.jh.global-shader
        open #{opt_prefix}/GlobalShader.app     # allow when it asks

      Or take the signature into your own hands. Once:

        #{opt_libexec}/make-signing-cert.sh

      and then after each upgrade, from your own shell — where the keychain is reachable
      and Homebrew's sandbox is not in the way:

        codesign --force --sign "jh local codesign" #{opt_prefix}/GlobalShader.app

      That reproduces the same signature every time, so the permission survives and macOS
      asks nothing. The long version is in docs/install.md.
    EOS
  end

  test do
    system bin/"global-shader", "--version"
    # --check runs the whole translation — GLSL → SPIR-V → MSL → pipeline — with no window
    # and no Screen Recording permission. The one end-to-end check that runs unattended.
    system bin/"global-shader", "--check", pkgshare/"shaders/crt/crt.frag"
  end
end
