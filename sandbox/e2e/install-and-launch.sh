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
#      and with the launch options as Steam applies them (Steam closed);
#   5. adds --with-mods: the frameworks from GitHub, the Nexus-only mods listed to download.
# Exits 1 if any step fails.
#
#   docker compose -f sandbox/compose.yaml run --rm install-and-launch
#   PATCHES="2.5 …" docker compose -f sandbox/compose.yaml run --rm install-and-launch   (once there is a newer patch)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATCHES="${PATCHES:-2.5}"
[ -x "$PROTON/proton" ] || die "no Proton at $PROTON (set PROTON_TOOL or PROTON)"
mkdir -p "$WORK"; WORK="$(mktemp -d "$WORK/journey.XXXXXX")"
start_display
say "Proton:  $(cut -d' ' -f2- "$PROTON/version")"
build_stubs "$WORK/stub"
vc2019="$(fetch "$VC2019_URL" vc2019.exe)" || exit 2
say "Creating a fresh Proton prefix"
new_prefix "$WORK/c-base"

fails=0
addon_want() {   # addon_want <patch> <set> <kind>: "Name version, ..." from the installer's ADDON_SETS, as check names them
    sed -n '/^# >>> add-on sets/,/^# <<< add-on sets/p' "$NI" | awk -v p="$1" -v set="$2" -v kind="$3" '
        $2 == p && ("," $3 ",") ~ ("," set ",") && $4 == kind { gsub("_", " ", $1); s = s sep $1 " " $7; sep = ", " }
        END { print s }'
}
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
    # the releases the installer's ADDON_SETS pairs with this patch, as check names them
    want="$(addon_want "$patch" flight mod)"; want="${want#Let There Be Flight }, with $(addon_want "$patch" flight lib)"
    check_line "$WORK/check-$patch.log" "Let There Be Flight and what it needs: $want" \
        "^  Let There Be Flight: +${want//./\\.} \(kept up to date"
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
    # The mod set, after the launches (Cyber Engine Tweaks would load into the stand-in): its
    # frameworks come from GitHub; Virtual Atelier and the rest are on Nexus Mods only, so the
    # installer lists them to download.
    if HOME="$home" bash "$NI" update --yes --with-mods > "$WORK/mods-$patch.log" 2>&1; then
        want="$(addon_want "$patch" mods lib)"
        check_line "$WORK/mods-$patch.log" "the mod set's frameworks: $want" "^  Mods: +.*with ${want//./\\.} \\(kept up to date"
        check_line "$WORK/mods-$patch.log" "Cyber Engine Tweaks' loader gets the override too" "^  DLL override: +winmm,version = native,builtin"
        check_line "$WORK/mods-$patch.log" "the Nexus-only mods listed with their pages" \
            "Virtual Atelier \\(the Basic file\\): https://www\\.nexusmods\\.com/cyberpunk2077/mods/2987"
    else
        say "    FAIL: --with-mods exited with an error:"; tail -n 15 "$WORK/mods-$patch.log" | sed 's/^/        /'
        fails=$((fails + 1))
    fi
done

say
if [ "$fails" = 0 ]; then say "All checks passed for game patch(es): $PATCHES"; exit 0; fi
say "$fails check(s) failed (work folder: $WORK)"
exit 1
