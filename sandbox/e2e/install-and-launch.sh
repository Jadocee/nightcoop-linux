#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-and-launch.sh: the whole user journey, online, as a normal user. For each game
# patch it builds a Steam home as it looks after the game's first launch: a Proton prefix
# holding Steam's VS 2019 runtime, no overrides, no Proton build chosen. Then it:
#   1. runs the repository's nightcoop-install.sh with --with-flight (live nightcoop.net,
#      GitHub, Microsoft);
#   2. checks what `nightcoop-install.sh check` reports;
#   3. runs it again as `update`, which must find everything current and change nothing;
#   4. starts the stand-in game through Proton with the registry override alone (Steam open)
#      and with the launch options as Steam applies them (Steam closed).
# Exits 1 if any step fails.
#
#   docker compose -f sandbox/compose.yaml run --rm install-and-launch
#   PATCHES=2.31 docker compose -f sandbox/compose.yaml run --rm install-and-launch
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATCHES="${PATCHES:-2.5 2.31}"
[ -x "$PROTON/proton" ] || die "no Proton at $PROTON (set PROTON_TOOL or PROTON)"
mkdir -p "$WORK"; WORK="$(mktemp -d "$WORK/journey.XXXXXX")"
start_display
say "Proton:  $(cut -d' ' -f2- "$PROTON/version")"
build_stubs "$WORK/stub"
vc2019="$(fetch "$VC2019_URL" vc2019.exe)" || exit 2
say "Creating a fresh Proton prefix"
new_prefix "$WORK/c-base"

fails=0
check_line() {   # check_line <log> <description> <extended regex>
    if grep -E -q "$3" "$1"; then say "    pass: $2"; else say "    FAIL: $2"; fails=$((fails + 1)); fi
}

make_home() {   # make_home <home> <patch> : Steam's files for a user who has started the game once
    local h="$1" st="$1/.local/share/Steam"
    local game="$st/steamapps/common/Cyberpunk 2077"
    mkdir -p "$st/steamapps/common" "$st/config" "$st/userdata/12345/config" "$game/bin/x64" "$h/.steam"
    ln -s "$st" "$h/.steam/steam"; ln -s "$st" "$h/.steam/root"
    cp "$WORK/stub/cp77-$2.exe" "$game/bin/x64/Cyberpunk2077.exe"
    printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"apps"\n\t\t{\n\t\t\t"%s"\t\t"70000000000"\n\t\t}\n\t}\n}\n' \
        "$st" "$APPID" > "$st/steamapps/libraryfolders.vdf"
    printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"installdir"\t\t"Cyberpunk 2077"\n}\n' "$APPID" > "$st/steamapps/appmanifest_$APPID.acf"
    printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"\n\t\t\t}\n\t\t}\n\t}\n}\n' \
        > "$st/config/config.vdf"
    printf '"users"\n{\n\t"76561197960278073"\n\t{\n\t\t"AccountName"\t\t"sandbox"\n\t\t"MostRecent"\t\t"1"\n\t}\n}\n' \
        > "$st/config/loginusers.vdf"
    printf '"UserLocalConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"apps"\n\t\t\t\t{\n\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"LastPlayed"\t\t"1792540000"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n' \
        "$APPID" > "$st/userdata/12345/config/localconfig.vdf"
}

for patch in $PATCHES; do
    say; say "== Game patch $patch"
    home="$WORK/home-$patch"; st="$home/.local/share/Steam"
    game="$st/steamapps/common/Cyberpunk 2077"; compat="$st/steamapps/compatdata/$APPID"
    make_home "$home" "$patch"
    mkdir -p "$(dirname "$compat")"; clone_prefix "$WORK/c-base" "$compat"
    say "    Steam's first launch: VS 2019 runtime"
    STEAM_CLIENT="$st" install_vc "$compat" "$vc2019"
    say "    running nightcoop-install.sh (log: $WORK/install-$patch.log)"
    if ! HOME="$home" bash "$NI" install --yes --with-flight > "$WORK/install-$patch.log" 2>&1; then
        say "    FAIL: the installer exited with an error:"; tail -n 15 "$WORK/install-$patch.log" | sed 's/^/        /'
        fails=$((fails + 1)); continue
    fi
    HOME="$home" bash "$NI" check > "$WORK/check-$patch.log" 2>&1
    sed -n '/Current state/,$p' "$WORK/check-$patch.log" | sed 's/^/      /' | head -n 12
    check_line "$WORK/check-$patch.log" "RED4ext supports game $patch" "^  RED4ext: +[0-9.]+ \(supports game $patch\)"
    check_line "$WORK/check-$patch.log" "Microsoft's runtime is current" "^  C\+\+ runtime \(prefix\): +[0-9.]+ \(ok\)"
    check_line "$WORK/check-$patch.log" "winmm override in the prefix registry" "^  DLL override: +winmm.* = native,builtin in the prefix registry"
    check_line "$WORK/check-$patch.log" "a Proton build chosen for the game" "^  Proton for the game: .*\(chosen in Steam\)"
    check_line "$WORK/check-$patch.log" "launch options written" "^  launch options: +WINEDLLOVERRIDES=.*%command% --launcher-skip"
    check_line "$WORK/check-$patch.log" "no newer NightCoop build" "^  NightCoop update: +none; "
    case "$patch" in 2.5) ltbf=0.3.20 ;; *) ltbf=0.3.18 ;; esac   # the build each patch is paired with
    check_line "$WORK/check-$patch.log" "Let There Be Flight $ltbf and what it needs" \
        "^  Let There Be Flight: +${ltbf//./\\.}, with redscript, ArchiveXL [0-9.]+, TweakXL [0-9.]+, Input Loader [0-9.]+ \(kept up to date"
    if HOME="$home" bash "$NI" update --yes > "$WORK/update-$patch.log" 2>&1; then
        check_line "$WORK/update-$patch.log" "a second run changes nothing" "everything is up to date; nothing to do"
    else
        say "    FAIL: the second run exited with an error:"; tail -n 15 "$WORK/update-$patch.log" | sed 's/^/        /'
        fails=$((fails + 1))
    fi
    for how in "registry only (Steam open)" "with the launch options (Steam closed)"; do
        EXTRA_ENV=()
        [[ "$how" == with* ]] && EXTRA_ENV=("WINEDLLOVERRIDES=winmm=n,b")
        STEAM_CLIENT="$st" launch "$compat" "$game"
        EXTRA_ENV=()
        if [ "$RESULT" = started ]; then say "    pass: RED4ext started, $how ($DETAIL)"
        else say "    FAIL: $how: $RESULT ($DETAIL)"; fails=$((fails + 1)); fi
    done
done

say
if [ "$fails" = 0 ]; then say "All checks passed for game patch(es): $PATCHES"; exit 0; fi
say "$fails check(s) failed (work folder: $WORK)"
exit 1
