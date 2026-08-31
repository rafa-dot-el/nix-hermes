# hermes-agent — thin wrapper over upstream's own `packages.<system>.default`.
#
# Upstream's "default" is already the fully-loaded build (see the
# NousResearch/hermes-agent checkout, nix/packages.nix "full"): hermes CLI,
# hermes-agent, hermes-acp (ACP support), bundled TUI + web dashboard,
# passthru Electron desktop, STT (faster-whisper/"voice"), messaging
# gateways, ripgrep/git/ffmpeg/openssh on PATH, and the bundled plugins tree
# (disk-cleanup, kanban, ... — enabled at runtime via `hermes tools` /
# config.yaml, not a Nix concern). This wrapper changes three things:
#
#   1. Local Chromium on PATH for browser automation (upstream ships none).
#   2. TTS: drops the cloud backends (edge-tts, elevenlabs/tts-premium) in
#      favour of Piper — fully local, GPL-3, no API key, no per-call network
#      round-trip. A default voice model is fetched here with a verified
#      hash and baked into the store, so nothing downloads at first use
#      (upstream's own Piper path lazily runs `python -m
#      piper.download_voices` on first call otherwise).
#   3. browser-use CLI (Hermes' `browser_exec` tool backend) vendored and
#      put on PATH, so `_find_cli()` in tools/browser_use_cli.py finds it
#      immediately instead of lazily running `uv tool install browser-use`
#      on first use (a live PyPI fetch). It only attaches over CDP to an
#      already-running Chromium-family browser with
#      --remote-debugging-port — it launches nothing itself.
#   4. LSP language servers (pyright, typescript-language-server, gopls,
#      rust-analyzer, clangd, nixd) put on PATH so agent/lsp/servers.py
#      finds them via shutil.which() instead of agent/lsp/install.py's
#      default "auto" strategy live-fetching them via npm/go/pip on first
#      use. Still requires `lsp.install_strategy: manual` in config.yaml
#      (user/HM state, not a Nix concern) so install.py never attempts the
#      live fetch path for any server NOT in this list.
#   5. xclip/xsel put on PATH for vision/image-paste clipboard access
#      (hermes_cli/clipboard.py's X11 backend — this package targets X11;
#      add wl-clipboard here too if the target session moves to Wayland).
#
# Activating Piper is a config.yaml change (user/HM state, not a Nix
# concern — see nix/homeManagerModules.nix's `settings.tts` merge upstream):
#
#   tts:
#     provider: piper
#     piper:
#       voice: <passthru.piperVoicePath of this package>
#
{ lib, stdenv, makeWrapper, fetchurl, fetchFromGitHub, runCommand, chromium, hermes, pkgsHermesRev, python3Packages
, pyright, nodePackages, gopls, rust-analyzer, nixd, clang-tools, xclip, xsel, rustPlatform, pkgs
}:

let
  # browser-use CLI ("Browser Use 3.0" — https://browser-use.com) is
  # Hermes' default `browser_exec` tool backend (tools/browser_use_cli.py:
  # _BACKEND_KEY = "browser-use"). It is not consumed by hermes' own venv —
  # `_find_cli()` shells out to it via `shutil.which("browser-use")` as a
  # subprocess — so it's built and wrapped independently here, using this
  # flake's own nixpkgs-25.11 rather than pkgsHermesRev: no ABI to match,
  # it never shares a PYTHONPATH with hermes's sealed venv.
  #
  # Upstream otherwise lazily runs `uv tool install browser-use` on first
  # use (tools/browser_use_cli.py install_cli()) — a live PyPI fetch this
  # package should never need. `_find_cli()`'s probe order is managed-dir →
  # bare PATH → ~/.local/bin, checked *before* any install is attempted, so
  # putting our own `browser-use` on PATH (same technique as chromium
  # below) fully pre-empts the runtime install.
  #
  # It only calls into `browser_harness` (a CDP client attaching to an
  # already-running Chromium-family browser with --remote-debugging-port —
  # it does not launch or download one itself). browser-use's own heavier
  # deps (openai/anthropic/google-genai/groq/ollama SDKs) back a separate
  # autonomous-agent mode this codepath never reaches, so nixpkgs'
  # close-enough versions are fine even though upstream pins every
  # dependency with `==` — `dontCheckRuntimeDeps` skips the exact-version
  # metadata check the same way the Piper/onnxruntime fix above does.
  #
  # Versions pinned to what `uv tool install browser-use` actually resolved
  # (2026-08-31). Six of ~35 dependencies aren't in nixpkgs and are
  # vendored below as plain wheels — pure-Python, no native extensions, so
  # a wheel fetch with a verified hash is exactly as reproducible as a
  # from-source build here.
  mkWheel = { pname, version, url, hash, dependencies ? [ ] }:
    python3Packages.buildPythonPackage {
      inherit pname version dependencies;
      format = "wheel";
      src = fetchurl { inherit url hash; };
      dontCheckRuntimeDeps = true;
      doCheck = false;
    };

  uuid7 = mkWheel {
    pname = "uuid7";
    version = "0.1.0";
    url = "https://files.pythonhosted.org/packages/b5/77/8852f89a91453956582a85024d80ad96f30a41fed4c2b3dce0c9f12ecc7e/uuid7-0.1.0-py2.py3-none-any.whl";
    hash = "sha256-XiWbtjyMtK3tWSf/QbREqA0McSTooM7Xz0TvofXMz2E=";
  };

  cdpUse = mkWheel {
    pname = "cdp-use";
    version = "1.4.5";
    url = "https://files.pythonhosted.org/packages/56/12/386d8c6bf0448c43674e24d6194c3b57d62e5361e90bca3d58108819ad32/cdp_use-1.4.5-py3-none-any.whl";
    hash = "sha256-j44kNeOiDkAJ0pdBRBks88Ey9sKXEzjhVhmIFNm5Hss=";
    dependencies = with python3Packages; [ httpx typing-extensions websockets ];
  };

  fetchUse = mkWheel {
    pname = "fetch-use";
    version = "0.4.0";
    url = "https://files.pythonhosted.org/packages/57/97/d4104692aa5c99a30fea22b5adffd2ce35b1ad86ae5236766cfc1ae468f1/fetch_use-0.4.0-py3-none-any.whl";
    hash = "sha256-t4hfKQfnkgNz+nXc2wCv1uYDolqe4hUaoogfVGXhosA=";
  };

  browserUseSdk = mkWheel {
    pname = "browser-use-sdk";
    version = "3.4.2";
    url = "https://files.pythonhosted.org/packages/84/e9/6dd224f9056b09622751821a91aa899b6d99447a761c74c4aabf4afd6e45/browser_use_sdk-3.4.2-py3-none-any.whl";
    hash = "sha256-HG2sbkT0rE1VKjJJ0Cgst0PQ0Cu63aCT145Zk5LFBNM=";
    dependencies = with python3Packages; [ httpx pydantic ];
  };

  bubus = mkWheel {
    pname = "bubus";
    version = "1.5.6";
    url = "https://files.pythonhosted.org/packages/f5/54/23aae0681500a459fc4498b60754cb8ead8df964d8166e5915edb7e8136c/bubus-1.5.6-py3-none-any.whl";
    hash = "sha256-JUrjfNkpmUH16davsR+OPOBp+D5blHb4jGsuMpEvI30=";
    dependencies = with python3Packages; [ aiofiles anyio portalocker pydantic typing-extensions uuid7 ];
  };

  browserHarness = mkWheel {
    pname = "browser-harness";
    version = "0.1.9";
    url = "https://files.pythonhosted.org/packages/2d/30/b3a16bab90a306fccafa4b76cb6aaf7f9c1950b52f824ddb4e8543775ffe/browser_harness-0.1.9-py3-none-any.whl";
    hash = "sha256-uR637Mg9U/Ww/BWybK1aCek1eXwkrkqZIYHcKonMPNY=";
    dependencies = with python3Packages; [ cdpUse fetchUse pillow websockets ];
  };

  browserUseDeps = with python3Packages; [
    aiohttp
    anthropic
    anyio
    click
    cloudpickle
    google-api-core
    google-api-python-client
    google-auth
    google-auth-oauthlib
    google-genai
    groq
    httpx
    inquirerpy
    markdownify
    mcp
    ollama
    openai
    pillow
    posthog
    psutil
    pydantic
    pyotp
    pypdf
    python-docx
    python-dotenv
    reportlab
    requests
    rich
    screeninfo
    typing-extensions
    browserHarness
    browserUseSdk
    bubus
    cdpUse
  ];

  # browser_harness/admin.py re-execs itself as a daemon:
  # `subprocess.Popen([sys.executable, "-m", "browser_harness.daemon"], env={**os.environ, ...})`.
  # nixpkgs' buildPythonApplication wrapper does NOT set PYTHONPATH — it
  # injects dependencies via `site.addsitedir()` calls baked into the
  # wrapper script itself, which only apply to that one process, not to
  # subprocesses re-invoking the bare interpreter (verified: `sys.executable`
  # inside the running app resolves to the plain, dependency-unaware
  # `python3.13` binary). Without an explicit PYTHONPATH, that respawned
  # daemon fails immediately with `ModuleNotFoundError: browser_harness`.
  # makeWrapperArgs' `--set PYTHONPATH` becomes a real exported env var,
  # which — unlike addsitedir — *does* propagate through Popen's env
  # inheritance to the child.
  browserUsePythonPath = lib.makeSearchPath python3Packages.python.sitePackages
    (python3Packages.requiredPythonModules browserUseDeps);

  browserUse = python3Packages.buildPythonApplication {
    pname = "browser-use";
    version = "0.13.8";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/f4/99/fb6deb5ae067f89dde22c1688211f53b71aa043e6077065a8ffee95a0d79/browser_use-0.13.8-py3-none-any.whl";
      hash = "sha256-nqTbG3lQTwKLAe7EnRXNRnSSk5UBACPwm6ykW12sst8=";
    };
    dependencies = browserUseDeps;
    makeWrapperArgs = [ "--set" "PYTHONPATH" browserUsePythonPath ];
    dontCheckRuntimeDeps = true;
    doCheck = false;
  };

  # buzz CLI (crates/buzz-cli in block/buzz) — plugins/platforms/buzz/adapter.py
  # shells out to it (`shutil.which("buzz")` / $BUZZ_CLI_PATH) for nearly
  # every operation: auth, channel/DM listing, sending, reactions. Built
  # from source (rustls-only — reqwest/tokio-tungstenite pin "rustls"
  # everywhere in the workspace Cargo.toml, so no openssl-sys/native-tls
  # system dependency) rather than fetching a release binary; block/buzz
  # ships no standalone `buzz` CLI release artifact anyway, only desktop-app
  # builds. Building against the pinned Cargo.lock in a monorepo pulls in
  # two non-crates.io git dependencies transitively present in the *lock
  # file* (not necessarily buzz-cli's own dependency graph — Nix's lockfile
  # vendoring has no per-target pruning) — both pinned by content hash via
  # outputHashes below, not by branch.
  #
  # Verified: full build succeeds with only these two outputHashes — no
  # other git dependency needed pinning. (crates.io's download redirector,
  # https://crates.io/api/v1/crates/.../download, intermittently 403'd
  # partway through the first attempt in this sandbox — retried clean.)
  buzzCliSrc = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    rev = "3e48f1b2365d326ee1c9582448d86a99b44ecd5d"; # v0.5.2
    hash = "sha256-VWqoIS5FMyou6fEuuUq1OUIPycAtn0kVLbm5yCQAsOs=";
  };
  buzzCli = rustPlatform.buildRustPackage {
    pname = "buzz-cli";
    version = "0.5.2";
    src = buzzCliSrc;
    cargoLock = {
      lockFile = "${buzzCliSrc}/Cargo.lock";
      outputHashes = {
        # tlongwell-block/rust-s3 fork, pinned by rev in buzz's own Cargo.toml
        "aws-creds-0.39.1" = "sha256-QAAm1phmeLFtDRgfDCoHijN1ce/rYzh18KziOUbL+hw=";
        # Mesh-LLM/mesh-llm — dozens of crates share this one repo+rev (see
        # buzz-agent's local-LLM runtime, unrelated to buzz-cli itself, but
        # still present in the shared workspace Cargo.lock); one outputHashes
        # entry covers the whole checkout for Nix's vendoring purposes.
        "mesh-llm-api-client-0.73.1" = "sha256-2ArkxK7Ze13mqkQB+JkuqVSCLeHpdxXHMZ0592VyEWw=";
      };
    };
    # Only build the CLI binary, not the rest of this large workspace
    # (admin-web/desktop/mobile/relay/agent/... aren't Nix concerns here).
    cargoBuildFlags = [ "-p" "buzz-cli" ];
    doCheck = false;
  };

  # cua-driver — the MCP-over-stdio backend for the computer_use toolset
  # (tools/computer_use/cua_backend.py). Unlike buzz-cli, trycua/cua ships
  # its OWN Nix packaging (nix/cua-driver/package.nix) — same rationale as
  # consuming hermes-agent-src's own flake instead of re-deriving it by
  # hand: reuse upstream's maintained package.nix rather than a worse copy.
  # Zero git dependencies (every crate is a plain crates.io registry
  # dependency per that file's own comment), so no outputHashes needed —
  # only the source fetch's own hash. rustls-only (ureq), no openssl-sys.
  # Building only "-p cua-driver --features portal-input,portal-capture"
  # (Linux binary; the workspace's macOS/Windows platform crates are
  # cfg-gated out) pulls in x11rb/pipewire/libei for XTest (X11) and the
  # GNOME/KDE portal ScreenCast+RemoteDesktop stack (Wayland) — matching
  # the docs' own prereq table (DISPLAY or XDG_SESSION_TYPE=wayland,
  # AT-SPI enabled on the DE).
  cuaDriverSrc = fetchFromGitHub {
    owner = "trycua";
    repo = "cua";
    # trycua/cua tags the cua-driver-rs component separately from the
    # repo-wide "vX.Y.Z" tags (those are the Python SDK's); nix/cua-driver/
    # only exists as of this component-specific tag.
    rev = "e88e9d899ac5effaeae38619527ebaa46b26ce72"; # cua-driver-rs-v0.23.2
    hash = "sha256-zM1hKX4Ri4j7sFbly14fBxGQ3/YDdtdsidvlWipcDMw=";
  };
  cuaDriver = import "${cuaDriverSrc}/nix/cua-driver/package.nix" {
    inherit pkgs;
    src = "${cuaDriverSrc}/libs/cua-driver/rust";
  };

  # agent-browser (vercel-labs/agent-browser) — the CDP-driving CLI behind
  # Hermes' *built-in* browser toolset (browser_navigate/click/type/snapshot/
  # …, tools/browser_tool.py). Distinct from browser-use above: browser.backend
  # auto-prefers Browser Use mode (browser_exec) when browser-use is on PATH,
  # but ACP mode's own tool allowlist (acp_adapter/tools.py) never includes
  # browser_exec — only the built-in agent-browser-backed tools — so ACP's
  # `hermes acp --setup-browser` (npm install -g agent-browser + a live
  # Playwright Chromium download into ~/.hermes/node/) is a real, separate
  # gap this package didn't close.
  #
  # The npm package ships prebuilt per-platform binaries with no visible
  # source (files: bin/, not cli/src/) — not something to vendor as an
  # opaque blob. The actual source is a Rust crate at vercel-labs/
  # agent-browser's cli/ (Apache-2.0, crates.io-only deps, no git deps in
  # Cargo.lock), so it's built from source here exactly like buzz-cli/
  # cua-driver above, pinned to the same version the npm package currently
  # publishes (0.35.2).
  #
  # install.rs's own fallback for "no bundled Chrome for Testing" is
  # `--executable-path`/$AGENT_BROWSER_EXECUTABLE_PATH — wired below via
  # makeWrapperArgs so it always resolves to our chromium and never even
  # attempts the googlechromelabs.github.io download.
  #
  # @askjo/camofox-browser (the other half of `--setup-browser`) is a
  # separate anti-detection Firefox fork with its own REST server
  # (tools/browser_camofox.py — Docker or its own git-clone build), an
  # entirely different runtime, opt-in and off by default. Out of scope
  # here — not needed for the core browser toolset --setup-browser exists
  # to unblock.
  agentBrowserSrc = fetchFromGitHub {
    owner = "vercel-labs";
    repo = "agent-browser";
    rev = "118af8eef1eebe21b949c3cf677d468330da7a46"; # v0.35.2
    hash = "sha256-7fNCG3Gu8a/93suVyDSxsOY2olWjPBaCDr8zvHrcWuY=";
  };
  agentBrowser = rustPlatform.buildRustPackage {
    pname = "agent-browser";
    version = "0.35.2";
    src = "${agentBrowserSrc}/cli";
    cargoLock.lockFile = "${agentBrowserSrc}/cli/Cargo.lock";
    doCheck = false;
    postFixup = ''
      wrapProgram "$out/bin/agent-browser" --set AGENT_BROWSER_EXECUTABLE_PATH "${chromium}/bin/chromium"
    '';
    nativeBuildInputs = [ makeWrapper ];
  };

  # Built from hermes-agent-src's OWN nixpkgs-unstable pin (passed in as
  # pkgsHermesRev), not this flake's nixpkgs-25.11 — piper-tts is a
  # buildPythonApplication with native extensions (onnxruntime, a cmake/
  # cython core), and it lands on hermes's PYTHONPATH via
  # extraPythonPackages below. Building it against a different nixpkgs
  # revision risks a python3.12/glibc ABI mismatch against the sealed
  # uv2nix venv it's injected into.
  # nixpkgs' top-level `piper-tts` resolves against whatever `python3`
  # currently defaults to in that revision (observed: 3.14, NOT the 3.12
  # hermes-agent.nix pins its own venv to) — rebuild the same package.nix
  # explicitly against python312.pkgs so the site-packages path
  # ("lib/python3.12/site-packages") and native-extension ABI actually
  # match the venv it's injected into below.
  # Top-level callPackage, not `python312.pkgs.callPackage` — the latter's
  # scope poisons the `python3Packages` name (`throw "do not use
  # python3Packages ..."`, see pkgs/top-level/python-aliases.nix) precisely
  # to stop packages *inside* a python set from re-grabbing the whole set.
  # We're the opposite case: injecting a package built for python3.12 into a
  # foreign venv, so we explicitly pass `python3Packages` from the top level.
  piperTtsApp =
    (pkgsHermesRev.callPackage
      "${pkgsHermesRev.path}/pkgs/by-name/pi/piper-tts/package.nix"
      {
        python3Packages = pkgsHermesRev.python312.pkgs;
        # Inference only: training pulls in torch/lightning/tensorboard for a
        # feature this package never uses.
        withTrain = false;
        withHTTP = false;
        withAlignment = false;
      }).overridePythonAttrs
      (old: {
        # hermes's own sealed venv already carries onnxruntime (transitively,
        # via the "voice"/faster-whisper dependency group) — the collision
        # check in hermes-agent.nix's installPhase rejects any
        # extraPythonPackages closure that duplicates a package already
        # inside the venv. Piper only calls the stable onnxruntime
        # InferenceSession API, so it's safe to drop piper's own copy and
        # let it resolve against hermes's, instead of vendoring two.
        #
        # All three are needed together (verified by inspecting the actual
        # propagatedBuildInputs, not assumed): `dependencies` is what
        # actually drives propagatedBuildInputs (pythonRemoveDeps alone left
        # onnxruntime in there); pythonRemoveDeps patches the wheel's own
        # dist-info METADATA (source pyproject.toml still declares it,
        # independent of the Nix `dependencies` attr); dontCheckRuntimeDeps
        # skips pythonRuntimeDepsCheckHook re-flagging the now-removed
        # requirement as "not installed".
        dependencies = builtins.filter (p: (p.pname or p.name or "") != "onnxruntime") old.dependencies;
        pythonRemoveDeps = [ "onnxruntime" ];
        dontCheckRuntimeDeps = true;
      });

  # piper-tts is packaged upstream as buildPythonApplication, not a library
  # in python3Packages — hermes-agent.nix's extraPythonPackages mechanism
  # walks `python312.pkgs.requiredPythonModules`, which only recognizes
  # actual python modules. `toPythonModule` is nixpkgs' standard bridge for
  # exposing an application's site-packages as an importable dependency.
  piperTts = pkgsHermesRev.python312.pkgs.toPythonModule piperTtsApp;

  # "Hey Hermes" wake word (hermes_cli/config_defaults.py: wake_word.provider,
  # default "openwakeword"). Traced a live failure: `wake.start` errors with
  # "No solution found when resolving dependencies... tflite-runtime has no
  # wheels with a matching Python ABI tag (cp312)" — openwakeword's own
  # tflite-runtime dependency genuinely publishes no Python 3.12 wheel for
  # Linux, so no pip/uv install (lazy or otherwise) can ever satisfy it.
  # This isn't a gap in our packaging: upstream's own nix/packages.nix
  # "full" build omits "wake" from extraDependencyGroups for the same
  # reason. "sherpa" (any phrase, no training — see wake_word.provider
  # options in config_defaults.py) has no such gap and is already in
  # nixpkgs, so it's wired in here instead of leaving wake word dead.
  # Activate with `wake_word.provider: sherpa` in config.yaml.
  #
  # nixpkgs' sherpa-onnx/sentencepiece (1.13.3/0.2.1) aren't quite what's
  # needed here: hermes_cli's own lazy-install allowlist (tools/lazy_deps.py
  # LAZY_DEPS["wake.sherpa"]) pins sherpa-onnx==1.13.4 and
  # sentencepiece==0.2.2 *exactly*, and its `_is_satisfied()` check compares
  # the installed version against that exact pin — a one-patch-version
  # mismatch reads as "not satisfied" and hermes tries to live-`pip install`
  # the pinned version into the (read-only) Nix store, which fails outright.
  # Vendoring the exact pinned PyPI wheels sidesteps that entirely: no
  # native rebuild needed, both ship prebuilt manylinux cp312 wheels.
  # sherpa-onnx-core carries the shared libraries only (libonnxruntime.so,
  # libsherpa-onnx-c-api.so, libsherpa-onnx-cxx-api.so under
  # sherpa_onnx/lib/) — no Python extension of its own, just autoPatchelfHook
  # so those .so's own NEEDED entries (libstdc++ etc) resolve under NixOS.
  sherpaOnnxCore = pkgsHermesRev.python312.pkgs.buildPythonPackage {
    pname = "sherpa-onnx-core";
    version = "1.13.4";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/41/be/38c57721d71ee74d984b1ca21720a8ca8477d6d341026af24ff658866ef9/sherpa_onnx_core-1.13.4-py3-none-manylinux2014_x86_64.whl";
      hash = "sha256-NnqgbO6Qs/15WdTgcdb8ghcQuFmvOZtJh+XDEZ7mrio=";
    };
    nativeBuildInputs = [ pkgsHermesRev.autoPatchelfHook ];
    buildInputs = [ pkgsHermesRev.stdenv.cc.cc.lib ];
    dontCheckRuntimeDeps = true;
    doCheck = false;
  };

  # sherpa-onnx (the main wheel) carries the actual Python extension —
  # sherpa_onnx/lib/_sherpa_onnx.cpython-312-*.so — which links against
  # sherpa-onnx-core's libonnxruntime.so etc. Those live in a *different*
  # Nix store path, so autoPatchelfHook needs sherpaOnnxCore in
  # buildInputs to add its lib dir to the RPATH (plain PYTHONPATH/site-dir
  # coexistence isn't enough — this is a runtime linker resolution, not a
  # Python import one).
  wakeExtraPythonPackages =
    let
      mkHermesWheel = { pname, version, url, hash, dependencies ? [ ], extra ? { } }:
        pkgsHermesRev.python312.pkgs.buildPythonPackage ({
          inherit pname version dependencies;
          format = "wheel";
          src = fetchurl { inherit url hash; };
          dontCheckRuntimeDeps = true;
          doCheck = false;
        } // extra);
    in
    [
      (mkHermesWheel {
        pname = "sherpa-onnx";
        version = "1.13.4";
        url = "https://files.pythonhosted.org/packages/cc/b1/8dfe5d1d72c92ea1c95db999a95b61bfbb9769f1c569f06e572eda095c52/sherpa_onnx-1.13.4-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl";
        hash = "sha256-XwFY81E9Otqx67oMJvDIFeU7oTuWhG2S7wla4l1kiGA=";
        dependencies = [ sherpaOnnxCore ];
        extra = {
          nativeBuildInputs = [ pkgsHermesRev.autoPatchelfHook ];
          buildInputs = [ sherpaOnnxCore pkgsHermesRev.stdenv.cc.cc.lib ];
          # autoPatchelfHook only scans buildInputs' top-level lib/lib64 by
          # default — sherpaOnnxCore's actual .so's are nested under its
          # own site-packages/sherpa_onnx/lib/, so its search path needs
          # adding explicitly (same technique as packages/grok-bot).
          preFixup = ''
            addAutoPatchelfSearchPath "${sherpaOnnxCore}/${pkgsHermesRev.python312.sitePackages}/sherpa_onnx/lib"
          '';
        };
      })
      (mkHermesWheel {
        pname = "sentencepiece";
        version = "0.2.2";
        url = "https://files.pythonhosted.org/packages/b6/2d/37e3da037318a70066ded0d51bc2a7f35491ae6338dd993d5eb1503fc3b5/sentencepiece-0.2.2-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
        hash = "sha256-yKFosEC8YWgSk/ealJtdkRyOJQhvQmAoW42Xq18Rldo=";
      })
      # sherpa_onnx's keyword-spotter lazily imports pypinyin (Chinese
      # phrase matching) at first wake-word use — not top-level, so it
      # didn't surface until actually enabling wake_word. Not in hermes'
      # own LAZY_DEPS allowlist at all (an upstream omission, not a
      # version to match), so no exact pin to chase — nixpkgs' pypinyin
      # has no dependencies of its own, no collision risk.
      pkgsHermesRev.python312.pkgs.pypinyin
    ];

  # en_GB-alba-medium, not the piper1-gpl default (en_US-lessac-medium):
  # matches the voice already deployed on Rafael's own Piper TTS daemon
  # (src/tts-daemon/default.nix, TTS_VOICE_MODEL) — one voice across every
  # tool that talks, not a second arbitrary default.
  piperVoiceName = "en_GB-alba-medium";

  # Hashes obtained via `nix store prefetch-file` against the upstream
  # rhasspy/piper-voices HuggingFace repo (content-addressed, verified —
  # not hand-copied from a download page).
  piperVoiceOnnx = fetchurl {
    url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/${piperVoiceName}.onnx";
    hash = "sha256-QBNpxKgdCf3YbDLFyGRECBHb3MZkZs3i1k9xM6Zq0Ds=";
  };
  piperVoiceConfig = fetchurl {
    url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/${piperVoiceName}.onnx.json";
    hash = "sha256-qpZaLwLsztYywmlOH8crv/bWXyZfq1Z8qUWRjHPdifQ=";
  };

  # PiperVoice.load() reads the sibling "<name>.onnx.json" next to the
  # model, so both files must share one directory under their real names
  # (fetchurl's own store paths are hash-named).
  piperVoiceDir = runCommand "hermes-piper-voice-${piperVoiceName}" { } ''
    mkdir -p "$out"
    ln -s ${piperVoiceOnnx} "$out/${piperVoiceName}.onnx"
    ln -s ${piperVoiceConfig} "$out/${piperVoiceName}.onnx.json"
  '';

  # Chromium/browser-use (browser_exec), the six LSP servers
  # (agent/lsp/servers.py's server_id → binary map), X11 clipboard tools
  # (vision/image-paste), and the buzz CLI (Buzz/Nostr platform plugin) —
  # all put on the wrapped binaries' PATH so nothing lazily fetches itself
  # at runtime.
  extraPathTools = [
    chromium
    browserUse
    pyright
    nodePackages.typescript-language-server
    gopls
    rust-analyzer
    nixd
    clang-tools # provides clangd
    xclip
    xsel
    buzzCli
    cuaDriver
    agentBrowser
  ];

  # faster-whisper (stt.local, config default "base") is already pulled in
  # by the "voice" dependency group, but WhisperModel("base", ...) — called
  # with no download_root/local_files_only in tools/transcription_tools.py —
  # resolves "base" as a Hugging Face repo alias (Systran/faster-whisper-base)
  # and lazily downloads it via huggingface_hub on first use otherwise.
  # faster_whisper.download_model() treats an existing directory path as a
  # ready-made local model, so pointing stt.local.model at this directory in
  # config.yaml (user/HM state, not a Nix concern) sidesteps the live fetch
  # entirely — same fetchurl + verified-hash pattern as the Piper voice above.
  fasterWhisperModelName = "base";
  fasterWhisperModelDir = runCommand "hermes-faster-whisper-${fasterWhisperModelName}" { } ''
    mkdir -p "$out"
    ln -s ${fetchurl {
      url = "https://huggingface.co/Systran/faster-whisper-${fasterWhisperModelName}/resolve/main/config.json";
      hash = "sha256-VqbYEQ0xHxnI8EceVigyx1J/FGtWcnW/yln898GE2po=";
    }} "$out/config.json"
    ln -s ${fetchurl {
      url = "https://huggingface.co/Systran/faster-whisper-${fasterWhisperModelName}/resolve/main/model.bin";
      hash = "sha256-0BwwFIgcnG8xM8GC89KIfrbKHHiadTjFwAcZaFegpqk=";
    }} "$out/model.bin"
    ln -s ${fetchurl {
      url = "https://huggingface.co/Systran/faster-whisper-${fasterWhisperModelName}/resolve/main/tokenizer.json";
      hash = "sha256-+3tjGR6bsEUILHn9dCoxBqEsmVE6sw30oNR/pstv0Ks=";
    }} "$out/tokenizer.json"
    ln -s ${fetchurl {
      url = "https://huggingface.co/Systran/faster-whisper-${fasterWhisperModelName}/resolve/main/vocabulary.txt";
      hash = "sha256-NM4/4cUEECez+NQpEicJk/mG28S7NM8n+VHjSh5FORM=";
    }} "$out/vocabulary.txt"
  '';

  base = hermes.minimal.override {
    # Mirrors upstream's own "full" package (nix/packages.nix) minus
    # edge-tts/tts-premium, since Piper replaces the cloud TTS backends here.
    extraDependencyGroups = [
      "anthropic"
      "azure-identity"
      "bedrock"
      "daytona"
      "dingtalk"
      "exa"
      "fal"
      "feishu"
      "firecrawl"
      "hindsight"
      "honcho"
      "messaging"
      "modal"
      "parallel-web"
      "vercel"
      "voice"
      # mcp/httpx2/starlette are already pulled in via "all" (the "mcp"
      # group), so this adds no new packages — kept explicit to match
      # upstream's own extra name for the computer_use toolset.
      "computer-use"
    ]
    ++ lib.optionals stdenv.isLinux [ "matrix" ];
    extraPythonPackages = [ piperTts ] ++ wakeExtraPythonPackages;
  };

  # `self` closes the loop: passthru.hermesDesktop must spawn THIS fully
  # wrapped binary (chromium + piper), not the pre-wrap intermediate that
  # `.override` alone would leave baked into desktop.nix's hermesAgent
  # reference. Lazy evaluation makes this safe — self is only forced when
  # passthru.hermesDesktop is actually built, by which point it's fully
  # defined.
  self = base.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ makeWrapper ];

    postFixup = ''
      ${old.postFixup or ""}
      for bin in hermes hermes-agent hermes-acp; do
        wrapProgram "$out/bin/$bin" --suffix PATH : "${lib.makeBinPath extraPathTools}"
      done
      # Baked into $out (not just passthru) so it's an actual build input,
      # not inert metadata nix build would never realize.
      ln -s ${piperVoiceDir} "$out/share/hermes-agent/piper-voices"
      ln -s ${fasterWhisperModelDir} "$out/share/hermes-agent/faster-whisper-${fasterWhisperModelName}"
    '';

    passthru = (old.passthru or { }) // {
      piperVoicePath = "${piperVoiceDir}/${piperVoiceName}.onnx";
      fasterWhisperModelPath = "${fasterWhisperModelDir}";
      hermesDesktop = old.passthru.hermesDesktop.override { hermesAgent = self; };
    };
  });
in
self
