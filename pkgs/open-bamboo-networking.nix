{
  lib,
  stdenv,
  fetchgit,
  cmake,
  pkg-config,
  curl,
  openssl,
  zlib,
  uthash,
  # Plugin ABI series. Orca has asked for 02.03.00 since 2.3.2; the trailing
  # .99 is upstream's convention so it reads as newer than any stock build.
  pluginVersion ? "02.03.00.99",
}:

# Open Bamboo Networking — open-source drop-in for Bambu's proprietary
# libbambu_networking plugin (same dlsym ABI). Built for Orca Slicer; the
# libraries land in $out/plugins, and home.nix links them into Orca's data dir.
# Not in nixpkgs. Upstream vendors mosquitto and cJSON via CMake FetchContent,
# so both are fetched here and handed over as writable copies (it patches them).
let
  mosquitto-src = fetchgit {
    url = "https://github.com/eclipse/mosquitto.git";
    rev = "v2.1.2";
    hash = "sha256-Zl55yjuzQY2fyaKs/zLaJ7a3OONKTDQPaT+DpPURdZI=";
  };
  cjson-src = fetchgit {
    url = "https://github.com/DaveGamble/cJSON.git";
    rev = "v1.7.18";
    hash = "sha256-299Qdc3dgnBUY1/67+/BmXgEXVDVen7+a0P9EQk+4yI=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "open-bamboo-networking";
  version = "2.2.0";

  src = fetchgit {
    url = "https://github.com/ClusterM/open-bamboo-networking.git";
    rev = "v${finalAttrs.version}";
    hash = "sha256-VSX5j4FmLavPGs5x3ONGrI1b8Du5BKD4WzsmwJFFOak=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
  ];
  buildInputs = [
    curl
    openssl
    zlib
    uthash
  ];

  preConfigure = ''
    cp -r --no-preserve=mode ${mosquitto-src} "$NIX_BUILD_TOP/mosquitto"
    cp -r --no-preserve=mode ${cjson-src} "$NIX_BUILD_TOP/cjson"
    cmakeFlagsArray+=(
      "-DFETCHCONTENT_SOURCE_DIR_ECLIPSE_MOSQUITTO=$NIX_BUILD_TOP/mosquitto"
      "-DFETCHCONTENT_SOURCE_DIR_CJSON=$NIX_BUILD_TOP/cjson"
    )
  '';

  cmakeFlags = [
    (lib.cmakeFeature "OBN_CLIENT_TYPE" "orca_slicer")
    (lib.cmakeFeature "OBN_VERSION" pluginVersion)
    (lib.cmakeBool "OBN_RELEASE" true)
    (lib.cmakeBool "OBN_PATCH_CLIENT_CONF" false)
    (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
  ];

  passthru = { inherit pluginVersion; };

  meta = {
    description = "Open-source replacement for Bambu Lab's network plugin (Orca Slicer build)";
    homepage = "https://github.com/ClusterM/open-bamboo-networking";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.linux;
  };
})
