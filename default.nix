# Wrapper over upstream hermes-agent with: Chromium, Piper TTS, browser-use CLI,
# LSP servers, and clipboard tools pre-baked. Upstream's own uv2nix handles CLI/TUI/web/ACP.
# Piper activation: config.yaml { tts: { provider: piper, piper: { voice: <passthru.piperVoicePath> } } }
#
{ lib, stdenv, makeWrapper, fetchurl, fetchFromGitHub, runCommand, chromium, hermes, pkgsHermesRev, python3Packages
, pyright, nodePackages, gopls, rust-analyzer, nixd, clang-tools, xclip, xsel, rustPlatform, pkgs
}:

let
  # browser-use CLI is a subprocess (tools/browser_use_cli.py: _find_cli).
  # Baked here to avoid runtime uv tool install. Attaches over CDP to running
  # browser; does not launch one. Six ~35 deps vendored as wheels (missing from nixpkgs).
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

  # browser_harness re-execs as daemon via subprocess.Popen; requires explicit
  # PYTHONPATH since addsitedir() doesn't propagate to child processes.
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

  # buzz CLI is a Rust binary from block/buzz monorepo used by buzz/adapter.py.
  # Built from source (no standalone release); two git deps in Cargo.lock need outputHashes.
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

  # cua-driver (MCP backend for computer_use) uses trycua's own package.nix.
  # No git deps, no outputHashes needed.
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

  # agent-browser is the CDP CLI for browser_tool.py's built-in browser toolset.
  # Built from source (Rust, Apache-2.0, no git deps). AGENT_BROWSER_EXECUTABLE_PATH
  # wired to our chromium.
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

  # piper-tts built against upstream's nixpkgs revision (pkgsHermesRev) with
  # python3.12 to match the sealed venv. ABI mismatch if built against our nixpkgs-25.11.
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
        # Drop onnxruntime (already in hermes's venv). All three attrs needed:
        # dependencies drives propagatedBuildInputs, pythonRemoveDeps patches dist-info,
        # dontCheckRuntimeDeps prevents re-flagging the removed requirement.
        dependencies = builtins.filter (p: (p.pname or p.name or "") != "onnxruntime") old.dependencies;
        pythonRemoveDeps = [ "onnxruntime" ];
        dontCheckRuntimeDeps = true;
      });

  # toPythonModule bridges piper-tts (a buildPythonApplication) to extraPythonPackages.
  piperTts = pkgsHermesRev.python312.pkgs.toPythonModule piperTtsApp;

  # Wake word: sherpa (not openwakeword, which has no py3.12 wheel).
  # Exact pinned versions (sherpa-onnx 1.13.4, sentencepiece 0.2.2) required by
  # hermes's lazy-install check; nixpkgs has mismatched versions. Vendor wheels.
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

  # sherpa-onnx's .so files link against sherpaOnnxCore's in a different store path.
  # autoPatchelfHook needs sherpaOnnxCore in buildInputs to resolve RPATH.
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
          # autoPatchelfHook needs explicit search path for sherpaOnnxCore's nested .so's.
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
      # pypinyin lazy-loaded by sherpa_onnx's keyword-spotter; no exact pin needed.
      pkgsHermesRev.python312.pkgs.pypinyin
    ];

  # en_GB-alba-medium matches Rafael's own piper-tts daemon (src/tts-daemon).
  piperVoiceName = "en_GB-alba-medium";

  # Hashes from rhasspy/piper-voices HuggingFace repo (content-addressed, verified).
  piperVoiceOnnx = fetchurl {
    url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/${piperVoiceName}.onnx";
    hash = "sha256-QBNpxKgdCf3YbDLFyGRECBHb3MZkZs3i1k9xM6Zq0Ds=";
  };
  piperVoiceConfig = fetchurl {
    url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/${piperVoiceName}.onnx.json";
    hash = "sha256-qpZaLwLsztYywmlOH8crv/bWXyZfq1Z8qUWRjHPdifQ=";
  };

  # PiperVoice.load() requires .onnx and .onnx.json under real names in same dir.
  piperVoiceDir = runCommand "hermes-piper-voice-${piperVoiceName}" { } ''
    mkdir -p "$out"
    ln -s ${piperVoiceOnnx} "$out/${piperVoiceName}.onnx"
    ln -s ${piperVoiceConfig} "$out/${piperVoiceName}.onnx.json"
  '';

  # Chromium, browser-use, LSP servers, clipboard tools, and buzz CLI on PATH
  # to prevent runtime lazy-fetches.
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

  # STT model pre-fetched to avoid lazy download via huggingface_hub.
  # Config: stt.local.model → <this directory> in config.yaml.
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
      # computer-use already in "all"; kept explicit to match upstream's name.
      "computer-use"
    ]
    ++ lib.optionals stdenv.isLinux [ "matrix" ];
    extraPythonPackages = [ piperTts ] ++ wakeExtraPythonPackages;
  };

  # self closes the loop: hermesDesktop must reference THIS wrapped binary,
  # not the pre-wrap base. Lazy evaluation ensures self is fully defined when forced.
  self = base.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ makeWrapper ];

    postFixup = ''
      ${old.postFixup or ""}
      for bin in hermes hermes-agent hermes-acp; do
        wrapProgram "$out/bin/$bin" --suffix PATH : "${lib.makeBinPath extraPathTools}"
      done
      # Baked into $out as actual build inputs, not just inert metadata.
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
