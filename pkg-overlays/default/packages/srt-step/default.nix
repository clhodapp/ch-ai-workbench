# SPDX-License-Identifier: MIT
# The srt step of agent-sandbox's bash chain: a `bash` that starts
# sandbox-runtime around each shell command of `agent`, with the rules
# agent-sandbox wrote for the checkout (see srt-step.mjs). The
# home-manager module overrides `sandbox-runtime` with
# `runtime.sandboxRuntimePackage` and `agent` with each agent it builds a
# chain for; `bash` is the bash that runs outside an enrolled checkout.
{
  lib,
  stdenvNoCC,
  makeBinaryWrapper,
  nodejs,
  bash,
  sandbox-runtime ? null,
  agent ? "opencode",
}:
assert lib.assertMsg (sandbox-runtime != null)
  "srt-step needs sandbox-runtime: override it with the sandbox-runtime package";
stdenvNoCC.mkDerivation {
  pname = "agent-sandbox-srt-step-${agent}";
  version = "0.1.0";

  src = ./srt-step.mjs;
  dontUnpack = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm444 $src $out/lib/srt-step.mjs
    substituteInPlace $out/lib/srt-step.mjs \
      --replace-fail @srtIndex@ ${sandbox-runtime}/lib/node_modules/@anthropic-ai/sandbox-runtime/dist/index.js
    makeBinaryWrapper ${lib.getExe nodejs} $out/bin/bash \
      --add-flags "$out/lib/srt-step.mjs ${lib.escapeShellArg agent} ${lib.getExe bash} --"
    runHook postInstall
  '';

  meta = {
    description = "Runs each shell command of an agent inside sandbox-runtime, with the rules of its agent-sandbox checkout";
    license = lib.licenses.mit;
    mainProgram = "bash";
  };
}
