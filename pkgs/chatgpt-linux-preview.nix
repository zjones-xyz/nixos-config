{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  makeWrapper,
  steam-run,
}:

# OpenAI ChatGPT Linux desktop public preview (official .deb payload).
# nixpkgs' `chatgpt` package is currently darwin-only on this flake's 26.05
# pin, so this unpacks the Linux .deb directly and launches it inside
# steam-run's FHS runtime to satisfy the upstream binary's /usr-style loader
# and library expectations on NixOS.
stdenv.mkDerivation (finalAttrs: {
  pname = "chatgpt-linux-preview";
  version = "26.915.31945";

  src = fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${finalAttrs.version}_${if stdenv.hostPlatform.isAarch64 then "arm64" else "amd64"}.deb";
    hash = if stdenv.hostPlatform.isAarch64
      then "sha256-uUxJS18P18cg+m/M1e9gmHmv/GIzLKkw7Sm5B9U3vG0="
      else "sha256-0nqcApGc/khNzF80WEueqf0NemXGncyHK1vc+g77WYM=";
  };

  nativeBuildInputs = [
    dpkg
    makeWrapper
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" unpack
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/opt"
    cp -a unpack/usr/lib/chatgpt "$out/opt/chatgpt"

    mkdir -p "$out/share"
    cp -a unpack/usr/share/applications "$out/share/" 2>/dev/null || true
    cp -a unpack/usr/share/icons "$out/share/" 2>/dev/null || true

    mkdir -p "$out/bin"
    makeWrapper ${steam-run}/bin/steam-run "$out/bin/chatgpt" \
      --add-flags "$out/opt/chatgpt/ChatGPT"

    if [ -f "$out/share/applications/chatgpt.desktop" ]; then
      substituteInPlace "$out/share/applications/chatgpt.desktop" \
        --replace-fail "Exec=/usr/bin/chatgpt" "Exec=$out/bin/chatgpt" \
        --replace-fail "Icon=/usr/share/icons/hicolor/0x0/apps/chatgpt.png" "Icon=chatgpt"
    fi

    runHook postInstall
  '';

  meta = {
    description = "Official ChatGPT desktop app (Linux public preview)";
    homepage = "https://chatgpt.com/desktop";
    license = lib.licenses.unfree;
    mainProgram = "chatgpt";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
