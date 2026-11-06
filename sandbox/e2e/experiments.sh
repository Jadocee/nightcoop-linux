#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# experiments.sh: the verification matrix from the README ("How this was verified"), run
# with real Proton, the live NightCoop archives, their RED4ext and Microsoft's runtime
# installers, using the stand-in game. Every row has an expected result. The script exits
# 1 if a row differs: an assumption the installer is built on no longer holds, usually
# because a new Proton, RED4ext, NightCoop or Microsoft release changed something.
#
#   docker compose -f sandbox/compose.yaml run --rm experiments
set -uo pipefail
. "$(dirname "$0")/lib.sh"

[ -x "$PROTON/proton" ] || die "no Proton at $PROTON (set PROTON_TOOL or PROTON)"
mkdir -p "$WORK"; WORK="$(mktemp -d "$WORK/experiments.XXXXXX")"
start_display
say "Proton:  $(cut -d' ' -f2- "$PROTON/version")"
say "Fetching (cached in $CACHE):"
build_stubs "$WORK/stub"
nc25="$(nightcoop_for 2.5)" || exit 2
nc231="$(nightcoop_for 2.31)" || exit 2
vc2019="$(fetch "$VC2019_URL" vc2019.exe)" && vc2022="$(fetch "$VC2022_URL" vc2022.exe)" \
    && vc14="$(fetch "$VC14_URL" vc14.exe)" || exit 2
say "    Microsoft runtimes: VS 2019 $(hp pever "$vc2019"), VS 2022 $(hp pever "$vc2022"), v14 $(hp pever "$vc14")"

say "Preparing a fresh Proton prefix and the game folders"
new_prefix "$WORK/c-base"
mkgame "$WORK/g25" "$WORK/stub/cp77-2.5.exe" "$nc25"
mkgame "$WORK/g231" "$WORK/stub/cp77-2.31.exe" "$nc231"
mkgame "$WORK/g231-newer" "$WORK/stub/cp77-2.31.exe" "$nc231"
bsdtar -xf "$nc25" -C "$WORK/g231-newer" red4ext/RED4ext.dll bin/x64/winmm.dll   # the 2.5 RED4ext on 2.31
r4_25="$(hp pever "$WORK/g25/red4ext/RED4ext.dll" product)"
r4_231="$(hp pever "$WORK/g231/red4ext/RED4ext.dll" product)"
say "    RED4ext bundled for 2.5: $r4_25; for 2.31: $r4_231"
# RED4ext's own patch gate, as the installer models it (RED4EXT_COMPAT)
if hp r4ok "$r4_25" 3.0.80.51928 "$(sed -n 's/^RED4EXT_COMPAT="\(.*\)"/\1/p' "$NI")"; then newer_on_231=started; else newer_on_231=refused; fi

rows=() fails=0
row() {   # row <description> <expected> : compare RESULT with the expectation
    local verdict=pass
    [ "$RESULT" = "$2" ] || { verdict=FAIL; fails=$((fails + 1)); }
    rows+=("$(printf '%-4s  %-52s %-10s %-10s %s' "$verdict" "$1" "$2" "$RESULT" "$DETAIL")")
    say "    $verdict: expected $2, got $RESULT ($DETAIL)"
}
step() { say; say "== $*"; }

step "1. NightCoop unpacked, no override"
clone_prefix "$WORK/c-base" "$WORK/c1"; launch "$WORK/c1" "$WORK/g25"
row "mod files only" notloaded

step "2. Registry override, as the installer writes it (works with Steam open)"
clone_prefix "$WORK/c-base" "$WORK/c2"; set_override "$WORK/c2"; launch "$WORK/c2" "$WORK/g25"
row "registry override, Wine's own runtime" started

step "3. Launch-option override (WINEDLLOVERRIDES)"
clone_prefix "$WORK/c-base" "$WORK/c3"
EXTRA_ENV=("WINEDLLOVERRIDES=winmm=n,b"); launch "$WORK/c3" "$WORK/g25"; EXTRA_ENV=()
row "launch-option override" started

step "4. Steam's first-launch runtime (VS 2019)"
clone_prefix "$WORK/c-base" "$WORK/c4"; set_override "$WORK/c4"; install_vc "$WORK/c4" "$vc2019"
launch "$WORK/c4" "$WORK/g25"
row "Steam's VS 2019 runtime ($(runtime_of "$WORK/c4"))" error998

step "5. VS 2022 runtime over it"
clone_prefix "$WORK/c4" "$WORK/c5"; install_vc "$WORK/c5" "$vc2022"; launch "$WORK/c5" "$WORK/g25"
row "VS 2022 runtime ($(runtime_of "$WORK/c5"))" started

step "6. v14 runtime over it (what the installer installs)"
clone_prefix "$WORK/c4" "$WORK/c6"; install_vc "$WORK/c6" "$vc14"; launch "$WORK/c6" "$WORK/g25"
row "v14 runtime ($(runtime_of "$WORK/c6"))" started

step "7. Steam's VS 2019 installer run again after the fix"
clone_prefix "$WORK/c6" "$WORK/c7"; install_vc "$WORK/c7" "$vc2019"
before="$(runtime_of "$WORK/c6")" after="$(runtime_of "$WORK/c7")"
RESULT=kept; [ "$after" = "$before" ] || RESULT=replaced; DETAIL="$before -> $after"
row "runtime after VS 2019 installer reruns" kept
launch "$WORK/c7" "$WORK/g25"
row "RED4ext after that" started

step "8. RED4ext $r4_25 (bundled for 2.5) on game 2.31"
launch "$WORK/c6" "$WORK/g231-newer"
row "RED4ext $r4_25 on game 2.31" "$newer_on_231"

step "9. RED4ext $r4_231 (bundled for 2.31) on game 2.31"
launch "$WORK/c6" "$WORK/g231"
row "RED4ext $r4_231 on game 2.31" started

say; say "== Summary (work folder: $WORK)"
printf '%-4s  %-52s %-10s %-10s %s\n' "" "scenario" "expected" "result" "detail"
printf '%s\n' "${rows[@]}"
[ "$fails" = 0 ] && { say "All rows as expected."; exit 0; }
say "$fails row(s) differ from what the installer assumes."
exit 1
