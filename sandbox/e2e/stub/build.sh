#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# build.sh OUTDIR : cross-compile the stand-in Cyberpunk2077.exe once per game patch.
# Each patch is "name:file version:fixed product version", as the real executables have them
# (RED4ext.SDK's RED4EXT_V1_RUNTIME_VERSION_* constants). Add a line here for a new patch.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: build.sh OUTDIR}"
PATCHES=(
    "2.5:3.0.88.46235:2.5.0.0"
    "2.31:3.0.80.51928:2.3.1.0"
)
mkdir -p "$out"
for p in "${PATCHES[@]}"; do
    IFS=: read -r name fv pv <<<"$p"
    sed -e "s/@FV@/${fv//./,}/" -e "s/@PV@/${pv//./,}/" -e "s/@FVS@/$fv/" -e "s/@PVS@/$name/" \
        "$here/cp77stub.rc.in" > "$out/cp77-$name.rc"
    x86_64-w64-mingw32-windres "$out/cp77-$name.rc" -O coff -o "$out/cp77-$name.res"
    x86_64-w64-mingw32-gcc -O2 -static -o "$out/cp77-$name.exe" "$here/cp77stub.c" "$out/cp77-$name.res" -lwinmm
done
ls "$out"/cp77-*.exe
