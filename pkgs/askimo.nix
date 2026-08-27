{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  zstd,
  jdk25,
  alsa-lib,
  bzip2,
  brotli,
  libbsd,
  expat,
  fontconfig,
  freetype,
  libGL,
  libmd,
  libpng,
  libuuid,
  libx11,
  libxau,
  libxcb,
  libxdmcp,
  libxext,
  libxi,
  libxrender,
  libxtst,
  zlib,
  xdg-utils,
}:

# Askimo (https://askimo.chat) — open-source multi-LLM desktop chat client
# (ChatGPT/Claude/Gemini/Ollama). Not in nixpkgs. Upstream only ships a
# jpackage-built .deb (askimo-ai/askimo releases) — this unpacks that .deb's
# self-contained app image (Kotlin/Compose Desktop) and runs it on nixpkgs'
# jdk25 instead of the bundled JRE, rather than wrapping the .deb's own
# runtime in an FHS environment. The classpath/JVM flags below are copied
# from the .deb's own lib/app/Askimo.cfg (jpackage's generated launcher
# config) so they track exactly what upstream's own launcher passes.
stdenv.mkDerivation (finalAttrs: {
  pname = "askimo";
  version = "1.4.18";

  src = fetchurl {
    url = "https://github.com/askimo-ai/askimo/releases/download/v${finalAttrs.version}/Askimo-Desktop-linux-x64.deb";
    hash = "sha256-Fkk0P9qmftUgsWqu7f4M2BK2i1DyAwz6vvopFcfXU+k=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    zstd
  ];

  # Only libskiko-linux-x64.so (Compose Desktop's Skia binding) is an ELF
  # binary shipped by upstream — everything else here is JVM bytecode.
  # autoPatchelfHook patches that one .so against these; the rest are also
  # exposed on the wrapper's LD_LIBRARY_PATH below since some of them (JNA's
  # dbus-java native transport, in particular) are extracted from a jar to
  # /tmp and dlopen'd at runtime rather than linked at build time.
  buildInputs = [
    stdenv.cc.cc.lib
    alsa-lib
    bzip2
    brotli
    libbsd
    expat
    fontconfig
    freetype
    libGL
    libmd
    libpng
    libuuid
    libx11
    libxau
    libxcb
    libxdmcp
    libxext
    libxi
    libxrender
    libxtst
    zlib
  ];

  unpackPhase = ''
    runHook preUnpack
    ar x $src
    mkdir -p data
    tar --zstd -xf data.tar.zst -C data
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    install -dm755 "$out/share/askimo/app"
    cp data/opt/askimo/lib/app/*.jar "$out/share/askimo/app/"
    cp data/opt/askimo/lib/app/libskiko-linux-x64.so "$out/share/askimo/app/"
    mkdir -p "$out/share/askimo/app/resources"
    cp -r data/opt/askimo/lib/app/resources/. "$out/share/askimo/app/resources/" 2>/dev/null || true

    install -Dm644 data/opt/askimo/lib/Askimo.png "$out/share/icons/hicolor/512x512/apps/askimo.png"
    install -Dm644 data/opt/askimo/lib/askimo-Askimo.desktop "$out/share/applications/askimo.desktop"
    substituteInPlace "$out/share/applications/askimo.desktop" \
      --replace-fail "Exec=/opt/askimo/bin/Askimo" "Exec=$out/bin/askimo" \
      --replace-fail "Icon=/opt/askimo/lib/Askimo.png" "Icon=askimo"

    # The classpath value below is single-quoted so the wrapper script's own
    # bash doesn't glob-expand the trailing `/*` before exec — java does its
    # own directory-of-jars expansion on a `-cp dir/*` argument, but only if
    # it reaches java intact. Unquoted, bash expands it into ~190
    # space-separated jar paths, `-cp` swallows only the first, and the
    # second becomes the (nonsensical) main-class argument.
    makeWrapper ${jdk25}/bin/java "$out/bin/askimo" \
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath finalAttrs.buildInputs}" \
      --add-flags "-cp" \
      --add-flags "'$out/share/askimo/app/*'" \
      --add-flags "-Djpackage.app-version=${finalAttrs.version}" \
      --add-flags "-Dcompose.application.resources.dir=$out/share/askimo/app/resources" \
      --add-flags "-Dcompose.application.configure.swing.globals=true" \
      --add-flags "--add-modules" \
      --add-flags "jdk.incubator.vector" \
      --add-flags "--enable-native-access=ALL-UNNAMED" \
      --add-flags "-Dskiko.library.path=$out/share/askimo/app" \
      --add-flags "io.askimo.desktop.MainKt"

    runHook postInstall
  '';

  meta = {
    description = "AI assistant desktop app with multi-LLM support (ChatGPT/Claude/Gemini/Ollama) and local document intelligence";
    homepage = "https://askimo.chat";
    license = lib.licenses.agpl3Only;
    mainProgram = "askimo";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
  };
})
