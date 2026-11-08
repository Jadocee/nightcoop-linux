#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# End-to-end tests for nightcoop-install.sh against a synthetic Steam installation.
# Needs only bash, python3 and coreutils; no Steam, Wine or network access.
#
#   tests/run-tests.sh            run everything
#   KEEP=1 tests/run-tests.sh     keep the temporary folder for inspection

# Assertions are single-quoted strings evaluated by expect(), so variables used only
# inside them look unused to shellcheck.
# shellcheck disable=SC2016,SC2034

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../nightcoop-install.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/nightcoop-tests.XXXXXX")"
if [ "${KEEP:-0}" = 1 ]; then echo "test folder: $T"; else trap 'rm -rf "$T"' EXIT; fi
FIX="$T/fix"
PASS=0 FAILED=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mpass\033[0m %s\n' "$1"; }
flunk() { FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /' | tail -n 25; }
expect() { if eval "$2"; then pass "$1"; else flunk "$1" "${3:-}"; fi; }   # expect <name> <shell test> [context]
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

python3 -I "$HERE/mkfixtures.py" archives "$FIX" || { echo "fixture generation failed"; exit 1; }

# The script under test, pointed at local fixtures instead of the network.
NI="$T/nightcoop-install.sh"
sed -e "s#^NIGHTCOOP_SITE=.*#NIGHTCOOP_SITE=\"file://$FIX/site\"#" \
    -e "s#^RED4EXT_URL=.*#RED4EXT_URL=\"file://$FIX/red4ext-1.31.0.zip\"#" \
    -e "s#^RED4EXT_SHA=.*#RED4EXT_SHA=\"$(cat "$FIX/red4ext.sha256")\"#" \
    -e "s#^VCREDIST_URLS=.*#VCREDIST_URLS=(\"file://$FIX/site/vc_redist.x64.exe\")#" "$SCRIPT" |
    awk -v table="$FIX/addon-sets.txt" '   # the add-on sets from the fixtures
        /^# >>> add-on sets/ { print; print "ADDON_SETS=\""; while ((getline line < table) > 0) print line; print "\""; skip = 1; next }
        /^# <<< add-on sets/ { skip = 0 }
        !skip' > "$NI"
chmod +x "$NI"
for os in steamos:SteamOS cachyos:CachyOS arch:Arch; do
    printf 'NAME="%s"\nPRETTY_NAME="%s"\nID=%s\nID_LIKE=arch\n' "${os#*:}" "${os#*:}" "${os%%:*}" > "$T/os-${os%%:*}"
done

# Stand-ins for the programs the launch wrappers need, found on NIGHTCOOP_TOOL_PATH instead of
# PATH, so that whatever this machine has installed does not count.
tools() {   # tools <dir> <name>...
    local d="$1" n; shift; mkdir -p "$d"
    for n in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$d/$n"; chmod +x "$d/$n"; done
}
tools "$T/tools-none"
tools "$T/tools-cachy" game-performance powerprofilesctl mangohud
tools "$T/tools-gp" game-performance                        # as cachyos-settings 1.4.1 ships it: powerprofilesctl only
tools "$T/tools-tlp-old" game-performance tlpctl
gpnew() {   # gpnew <dir> <name>...: a newer game-performance, which knows tlpctl too
    tools "$@"; printf '#!/bin/sh\n# powerprofilesctl, or else tlpctl\nexit 0\n' > "$1/game-performance"; chmod +x "$1/game-performance"
}
gpnew "$T/tools-gp-new"
gpnew "$T/tools-tlp" tlpctl
tools "$T/tools-deck" mangohud powerprofilesctl
fpstub() {   # fpstub <dir> <branch>: Flatpak's command, Steam on the 26.08 runtime, MangoHud's extension for <branch>
    cat > "$1/flatpak" <<EOF
#!/bin/sh
case "\$*" in
    "info --show-runtime com.valvesoftware.Steam") echo org.freedesktop.Platform/x86_64/26.08 ;;
    "info org.freedesktop.Platform.VulkanLayer.MangoHud"|"info org.freedesktop.Platform.VulkanLayer.MangoHud//$2") echo MangoHud ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$1/flatpak"
}
# Flatpak Steam with MangoHud's extension for its runtime, or only the one for 25.08; and the
# host's game-performance, which Flatpak Steam cannot run
tools "$T/tools-fp" game-performance powerprofilesctl; fpstub "$T/tools-fp" 26.08
tools "$T/tools-fp-nomh"; fpstub "$T/tools-fp-nomh" 25.08

H="" OSR="$T/os-steamos" OUT="" TOOLS="$T/tools-none"
run() {   # run <args...> : output in $OUT, status in $RC
    OUT="$(env -i PATH="$PATH" HOME="$H" LANG=C.UTF-8 DISPLAY=:0 NIGHTCOOP_ALLOW_ROOT=1 \
           NIGHTCOOP_OS_RELEASE="$OSR" NIGHTCOOP_TOOL_PATH="$TOOLS" bash "$NI" "$@" 2>&1)"; RC=$?
}
hp() { bash "$SCRIPT" __py "$@"; }
newworld() {   # newworld <name> <layout> [options for mkfixtures.py world]
    H="$T/$1" TOOLS="$T/tools-none"; python3 -I "$HERE/mkfixtures.py" world "$H" "$FIX" "${@:2}"
    if [ "$2" = flatpak ]; then STEAM="$H/.var/app/com.valvesoftware.Steam/.local/share/Steam"; LIB="$STEAM"
    else STEAM="$H/.local/share/Steam"; LIB="$H/sdcard"; fi
    G="$LIB/steamapps/common/Cyberpunk 2077"
    PFX="$LIB/steamapps/compatdata/1091500/pfx"
    LC="$STEAM/userdata/12345/config/localconfig.vdf"
}
snapshot() { (cd "$1" && find . -print | sort && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
launch_opts() { sed -n 's/.*"LaunchOptions"[[:space:]]*"\(.*\)"$/\1/p' "$LC"; }
set_lo() { sed -i "s|\"LaunchOptions\"\([[:space:]]*\)\".*\"\$|\"LaunchOptions\"\1\"$1\"|" "$LC"; }   # a value without quotes
REG_KEY='Software\Wine\AppDefaults\Cyberpunk2077.exe\DllOverrides'

tool() { hp ct-get "$STEAM" 1091500 | cut -d$'\x1f' -f1; }
newest_backup() { find "$H/.local/share/nightcoop-linux/backups" -mindepth 1 -maxdepth 1 -type d | sort | tail -n1 | sed "s,$,/,"; }

# ---------------------------------------------------------------- helpers ----
section "Launch option merging"
lo() { hp lo-merge "$1" "${3:-winmm}" "${4:-}" "${5:-}" | cut -d$'\x1f' -f"$2"; }   # lo <line> <field> [dlls] [args] [wrappers]
expect "empty"                       '[ "$(lo "" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" ]'
expect "arguments only"              '[ "$(lo "--launcher-skip" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command% --launcher-skip" ]'
expect "CachyOS wrapper kept"        '[ "$(lo "game-performance %command%" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" game-performance %command%" ]'
expect "other overrides kept"        '[ "$(lo "WINEDLLOVERRIDES=\"version=n,b\" %command%" 2)" = "WINEDLLOVERRIDES=\"version=n,b;winmm=n,b\" %command%" ]'
expect "builtin winmm corrected"     '[ "$(lo "WINEDLLOVERRIDES=winmm=b mangohud %command%" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" mangohud %command%" ]'
expect "combined entry recognised"   '[ "$(lo "WINEDLLOVERRIDES=\"winmm,version=n,b\" %command%" 1)" = ok ]'
expect "override after %command%"    '[ "$(lo "%command% WINEDLLOVERRIDES=winmm=n,b" 1)" = broken ]'
expect "moved before %command%"      '[ "$(lo "%command% WINEDLLOVERRIDES=winmm=n,b" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" ]'
expect "--launcher-skip added after %command%" '[ "$(lo "game-performance %command% -skipStartScreen" 2 winmm --launcher-skip)" = "WINEDLLOVERRIDES=\"winmm=n,b\" game-performance %command% --launcher-skip -skipStartScreen" ]'
expect "missing argument means not done" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" 1 winmm --launcher-skip)" = missing ]'
expect "Cyber Engine Tweaks loader joins" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" 2 winmm,version)" = "WINEDLLOVERRIDES=\"winmm,version=n,b\" %command%" ]'
expect "game-performance goes last, right before %command%" '[ "$(lo "prime-run %command%" 2 winmm "" +game-performance)" = "WINEDLLOVERRIDES=\"winmm=n,b\" prime-run game-performance %command%" ]'
expect "game-performance not doubled" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" game-performance %command%" 1 winmm "" +game-performance)" = ok ]'
expect "game-performance taken out"  '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" game-performance %command% --launcher-skip" 2 winmm --launcher-skip -game-performance)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command% --launcher-skip" ]'
expect "a game argument of that name is not a wrapper" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" %command% game-performance" 1 winmm "" -game-performance)" = ok ]'
expect "nor is a variable set to a path of that name" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" TOOL=/opt/x/game-performance %command%" 1 winmm "" -game-performance)" = ok ]'
expect "MANGOHUD=1 after the overrides" '[ "$(lo "gamemoderun %command%" 2 winmm "" +mangohud)" = "WINEDLLOVERRIDES=\"winmm=n,b\" MANGOHUD=1 gamemoderun %command%" ]'
expect "the mangohud wrapper counts as MangoHud" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" mangohud %command%" 1 winmm "" +mangohud)" = ok ]'
expect "MANGOHUD=0 turned on"        '[ "$(lo "MANGOHUD=0 %command%" 2 winmm "" +mangohud)" = "WINEDLLOVERRIDES=\"winmm=n,b\" MANGOHUD=1 %command%" ]'
expect "MangoHud taken out: wrapper, its --dlsym and the variable" '[ "$(lo "MANGOHUD=1 mangohud --dlsym game-performance %command%" 2 winmm "" -mangohud)" = "WINEDLLOVERRIDES=\"winmm=n,b\" game-performance %command%" ]'
expect "a quoted value is one word, its spacing kept" '[ "$(lo "DXVK_HUD=\"fps,  memory\" %command%" 2 winmm "" +game-performance)" = "WINEDLLOVERRIDES=\"winmm=n,b\" DXVK_HUD=\"fps,  memory\" game-performance %command%" ]'

section "The fixtures' add-on table"
rows() { awk -v n="$2" 'NF == n { $NF = ""; if (n == 9) $(NF - 1) = ""; print }' "$1" | sort; }   # rows <file> <fields>: without source and SHA-256
expect "its GitHub rows are the installer's, but for their URL and SHA-256" '[ "$(rows "$FIX/addon-sets.txt" 9)" = "$(sed -n "/^ADDON_SETS=\"/,/^\"/p" "$SCRIPT" | rows /dev/stdin 9)" ] && [ "$(rows "$FIX/addon-sets.txt" 9 | wc -l)" = 9 ]'
expect "its Nexus rows are the installer's" '[ "$(awk "NF == 8" "$FIX/addon-sets.txt" | sort)" = "$(sed -n "/^ADDON_SETS=\"/,/^\"/p" "$SCRIPT" | awk "NF == 8 {\$1 = \$1; print}" | sort)" ]'

section "Release selection (releases.json, as nightcoop.net publishes it)"
pick() { hp pick "$FIX/site/releases.json" "$1" "https://nightcoop.net" "${2:-}" | tr '\037' '|'; }
expect "2.5 picks the 2.5 archive"    '[[ "$(pick 2.5,2.5)" == "ok|0.2.0-beta|https://nightcoop.net/dl/0.2.0-beta/NightCoop-0.2.0-beta-2.5.zip|"*"|2.5|164|1.31.0|1|0" ]]'
expect "2.31 picks the 2.31 archive"  '[[ "$(pick 2.31)" == "ok|0.2.0-beta|https://nightcoop.net/dl/0.2.0-beta/NightCoop-0.2.0-beta-2.31.zip|"*"|2.31|164|1.30.0|1|0" ]]'
expect "unknown game falls back"      '[[ "$(pick 9.9)" == ok\|0.2.0-beta\|*\|0\|0 ]]'
expect "local archive identified"     '[[ "$(pick 2.5 "$(sha256sum "$FIX/site/dl/0.1.1-beta.2/NightCoop-0.1.1-beta.2.zip" | cut -d" " -f1)")" == match\|0.1.1-beta.2\|* ]]'
expect "yanked build flagged"         '[[ "$(pick 2.5 "$(printf 2%.0s {1..64})")" == match\|0.1.0-beta.1\|*\|1 ]]'
expect "broken JSON reported"         '[[ "$(hp pick /dev/null 2.5 x)" == error* ]]'

section "Game versions and RED4ext pairing"
gv() { hp gamever "$FIX/pe/Cyberpunk2077-$1.exe" | tr '\037' '|'; }
expect "2.5 build read as patch 2.5"   '[ "$(gv 2.5)" = "2.5|2.5|3.0.88.46235" ]'
expect "2.31 build read as patch 2.31" '[ "$(gv 2.31)" = "2.31|2.31|3.0.80.51928" ]'
R4T="$(sed -n 's/^RED4EXT_COMPAT="\(.*\)"/\1/p' "$SCRIPT")"
r4() { hp r4ok "$1" "$2" "$R4T"; }
expect "RED4ext 1.31 runs on 2.5"      'r4 1.31.0 3.0.88.46235'
expect "RED4ext 1.31 refuses 2.31"     '! r4 1.31.0 3.0.80.51928'
expect "RED4ext 1.30 does not run on 2.5" '! r4 1.30.0 3.0.88.46235'
expect "a newer RED4ext is trusted on 2.5" 'r4 1.32.0 3.0.88.46235'

section "Steam's compatibility tool setting (config.vdf)"
CV="$T/ctvdf"; mkdir -p "$CV/config"
printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"X"\t\t"1"\n\t\t\t}\n\t\t}\n\t}\n}\n' > "$CV/config/config.vdf"
hp ct-set "$CV" 1091500 proton_experimental >/dev/null
expect "mapping created where none existed" '[ "$(hp ct-get "$CV" 1091500 | cut -d$'"'"'\x1f'"'"' -f1)" = proton_experimental ] && grep -q "\"priority\"[[:space:]]*\"250\"" "$CV/config/config.vdf"'
hp ct-set "$CV" 1091500 proton-cachyos-slr >/dev/null
expect "existing mapping replaced"     '[ "$(hp ct-get "$CV" 1091500 | cut -d$'"'"'\x1f'"'"' -f1)" = proton-cachyos-slr ] && [ "$(grep -c "\"1091500\"" "$CV/config/config.vdf")" = 1 ]'
expect "same value left alone"         '[ "$(hp ct-set "$CV" 1091500 proton-cachyos-slr)" = unchanged ]'
expect "other settings kept"           'grep -q "\"X\"" "$CV/config/config.vdf"'

section "Archive safety and versions"
expect "path traversal refused"       '! hp unzip "$FIX/evil.zip" "$T/evil" 2>/dev/null && [ ! -e "$T/escape.txt" ]'
expect "version compare pads"         'hp vge 1.31 1.31.0 && hp vge 14.51.36247.0 14.51 && ! hp vge 14.44.35211.0 14.51'

# ------------------------------------------------- SteamOS, game on SD card ----
section "SteamOS: game 2.5 on an SD card library, NightCoop once copied in by hand"
newworld deck native manual; OSR="$T/os-steamos"
PRISTINE_GAME="$(snapshot "$G")"; PRISTINE_SYS32="$(snapshot "$PFX/drive_c/windows/system32")"; PRISTINE_LO="$(launch_opts)"
run check
expect "check finds game on SD card"  '[ $RC = 0 ] && [[ "$OUT" == *"game folder: $LIB/"* ]] && [[ "$OUT" == *"game version: 2.5 (Cyberpunk2077.exe 3.0.88.46235)"* ]]' "$OUT"
expect "check flags Steam's 2019 runtime" '[[ "$OUT" == *"14.29.30157.0 (too old"* ]]' "$OUT"
expect "check offers the SteamOS protontricks route" '[[ "$OUT" == *"Discover: install \"Protontricks\""* ]]' "$OUT"
expect "check reports no Proton choice" '[[ "$OUT" == *"Proton for the game:"*"not chosen"* ]]' "$OUT"
BEFORE="$(snapshot "$H")"
run install --dry-run
expect "dry run succeeds"             '[ $RC = 0 ] && [[ "$OUT" == *"dry run finished"* ]]' "$OUT"
expect "dry run changes nothing"      '[ "$BEFORE" = "$(snapshot "$H")" ]'

run install --yes
expect "install succeeds"             '[ $RC = 0 ]' "$OUT"
expect "the 2.5 archive was chosen"   '[[ "$OUT" == *"NightCoop 0.2.0-beta (for game 2.5, protocol 164, bundles RED4ext 1.31.0)"* ]]' "$OUT"
expect "NightCoop in existing Plugins folder (no case duplicate)" '[ -f "$G/red4ext/Plugins/NightCoop/NightCoop.dll" ] && [ ! -e "$G/red4ext/plugins" ]'
expect "other plugin untouched"       '[ -f "$G/red4ext/Plugins/OtherMod/other.dll" ]'
expect "bundled RED4ext 1.31 used, nothing downloaded" '[ "$(hp pever "$G/red4ext/RED4ext.dll" product)" = 1.31.0 ] && [[ "$OUT" == *"using RED4ext 1.31.0 from the NightCoop archive"* ]] && [[ "$OUT" != *"downloading red4ext"* ]]' "$OUT"
expect "old build's leftover removed, as NightCoop's guide says" '[ ! -e "$G/red4ext/Plugins/NightCoop/old-helper.dll" ]'
expect "servers.txt and logs kept"    '[ -f "$G/red4ext/Plugins/NightCoop/servers.txt" ] && [ -f "$G/red4ext/Plugins/NightCoop/logs/nightcoop-last-crash.log" ]'
expect "runtime upgraded to 14.51"    '[ "$(hp pever "$PFX/drive_c/windows/system32/msvcp140.dll")" = 14.51.36247.0 ]'
expect "installer run with runinprefix" 'grep -q "^runinprefix .*vc_redist.x64.exe /install /quiet /norestart" "$PFX/../fake-proton.log"'
expect "newest installer chosen over Steamworks 14.44" '[[ "$OUT" == *"installer: $H/.cache/nightcoop-linux/vc_redist.x64.exe (14.51.36247.0)"* ]]' "$OUT"
expect "registry override written"    '[ "$(hp reg-get "$PFX/user.reg" "$REG_KEY" winmm)" = native,builtin ]'
expect "launch options merged"        '[ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" gamemoderun %command% --launcher-skip" ]' "$(launch_opts)"
expect "Proton Experimental chosen for the game" '[ "$(tool)" = proton_experimental ] && [[ "$OUT" == *"Proton for the game:"*"proton_experimental (chosen in Steam)"* ]]' "$OUT"
expect "saves backed up"              '[ -f "$(newest_backup)Saved Games/ManualSave-0/sav.dat" ]'
expect "check reports NightCoop"      '[[ "$OUT" == *"NightCoop:"*"0.2.0.0"*"release 0.2.0-beta"* ]]' "$OUT"
NRUNS="$(wc -l < "$PFX/../fake-proton.log")"
B1="$(newest_backup)"; G1="$(snapshot "$G")"; touch "$T/mark-deck"

run install --yes
expect "second install succeeds"      '[ $RC = 0 ]' "$OUT"
expect "runtime not reinstalled"      '[ "$(wc -l < "$PFX/../fake-proton.log")" = "$NRUNS" ] && [[ "$OUT" == *"runtime 14.51.36247.0 is new enough"* ]]' "$OUT"
expect "settings recognised"          '[[ "$OUT" == *"registry already has winmm"* ]] && [[ "$OUT" == *"launch options already set"* ]] && [[ "$OUT" == *"already chosen for this game"* ]]' "$OUT"
expect "with everything current, nothing is changed or backed up" '[[ "$OUT" == *"everything is up to date; nothing to do"* ]] && [ "$(newest_backup)" = "$B1" ] && [ "$G1" = "$(snapshot "$G")" ] && [ -z "$(find "$G" -type f -cnewer "$T/mark-deck")" ]' "$OUT"
expect "the archive is not downloaded again" '[[ "$OUT" == *"NightCoop-0.2.0-beta-2.5.zip was downloaded before"* ]] && [[ "$OUT" != *"downloading NightCoop"* ]]' "$OUT"

V1_GAME="$(snapshot "$G")"
run install --yes --nightcoop-zip "$FIX/NightCoop-0.2.1-test.zip"
expect "unlisted local archive installs with a warning" '[ $RC = 0 ] && [[ "$OUT" == *"not listed on"* ]]' "$OUT"
expect "bundled newer RED4ext 1.32 kept" '[ "$(hp pever "$G/red4ext/RED4ext.dll" product)" = 1.32.0 ] && [[ "$OUT" == *"using RED4ext 1.32.0 from the NightCoop archive"* ]]' "$OUT"
expect "files dropped by the new build removed" '[ ! -e "$G/red4ext/Plugins/NightCoop/legacy.dll" ] && [ ! -e "$G/archive/pc/mod/NightCoop.archive" ] && [[ "$OUT" == *"2 stale removed"* ]]' "$OUT"
expect "RED4ext licence files protected from stale removal" '[ -f "$G/red4ext/LICENSE.txt" ]'
expect "backslash paths unpacked"     '[ "$(hp pever "$G/red4ext/Plugins/NightCoop/NightCoop.dll")" = 0.2.1.0 ]'

run restore --yes
expect "restore succeeds"             '[ $RC = 0 ]' "$OUT"
expect "restore returns the previous build" '[ "$V1_GAME" = "$(snapshot "$G")" ]' "$(diff <(echo "$V1_GAME") <(snapshot "$G"))"

run uninstall --yes
expect "uninstall succeeds"           '[ $RC = 0 ] && [[ "$OUT" == *"install(s) undone"* ]]' "$OUT"
expect "game folder byte-identical to before (hand-copied files back too)" '[ "$PRISTINE_GAME" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_GAME") <(snapshot "$G"))"
expect "prefix runtime restored"      '[ "$PRISTINE_SYS32" = "$(snapshot "$PFX/drive_c/windows/system32")" ]'
expect "registry override removed"    '! hp reg-get "$PFX/user.reg" "$REG_KEY" winmm >/dev/null'
expect "Steam settings left as they are" '[ "$(launch_opts)" != "$PRISTINE_LO" ] && [ "$(tool)" = proton_experimental ]'
run restore --yes
expect "nothing left to restore"      '[ $RC != 0 ] && [[ "$OUT" == *"no backup to restore"* ]]' "$OUT"

# --------------------------------------------------------- Steam running ----
section "Steam open (the usual case on SteamOS)"
newworld open native; OSR="$T/os-steamos"
# A stand-in Steam process. A shebang script's process name is its file name, so this
# works whether or not sleep is a multi-call (coreutils/uutils/busybox) binary.
mkdir -p "$T/bin"; printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$T/bin/steam"; chmod +x "$T/bin/steam"
"$T/bin/steam" & STEAM_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x steam >/dev/null && break; sleep 0.2; done
expect "stand-in Steam process is visible" 'pgrep -u "$(id -u)" -x steam >/dev/null'
run install --yes
expect "install succeeds with Steam open" '[ $RC = 0 ]' "$OUT"
expect "Steam's files not touched"    '[ "$(launch_opts)" = "gamemoderun %command% --launcher-skip" ] && [ -z "$(tool)" ]'
expect "registry override still set"  '[ "$(hp reg-get "$PFX/user.reg" "$REG_KEY" winmm)" = native,builtin ]'
expect "launch options recommended"   '[[ "$OUT" == *"Recommended (the prefix override already lets the mod load)"*"WINEDLLOVERRIDES=\"winmm=n,b\" gamemoderun %command% --launcher-skip"* ]]' "$OUT"
expect "Proton choice explained"      '[[ "$OUT" == *"Properties > Compatibility"*"choose Proton Experimental"* ]]' "$OUT"
expect "no 'manual step' demanded"    '[[ "$OUT" != *"One manual step left"* ]]' "$OUT"
run install --yes
kill "$STEAM_PID" 2>/dev/null; wait "$STEAM_PID" 2>/dev/null
expect "rerun with Steam still open only repeats the recommendations" '[ $RC = 0 ] && [[ "$OUT" == *"nothing to replace"* ]] && [[ "$OUT" == *"Recommended (the prefix override already lets the mod load)"* ]] && [[ "$OUT" != *"Backing up"* ]]' "$OUT"
run install --yes
expect "rerun with Steam closed writes only Steam's settings" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" gamemoderun %command% --launcher-skip" ] && [ "$(tool)" = proton_experimental ] && [[ "$OUT" != *"Backing up"* ]]' "$OUT"

# ---------------------------------------------------------- Flatpak Steam ----
section "Flatpak Steam (sandbox paths in Steam's files)"
newworld flat flatpak; OSR="$T/os-arch"
run check
expect "Flatpak root detected"        '[ $RC = 0 ] && [[ "$OUT" == *"Steam (flatpak client): $STEAM"* ]]' "$OUT"
expect "sandbox config_info path mapped to the host" '[[ "$OUT" == *"Proton: Proton - Experimental"*"prefix'"'"'s last launch"* ]]' "$OUT"
run install --yes
expect "install succeeds"             '[ $RC = 0 ] && [ -f "$G/red4ext/Plugins/NightCoop/NightCoop.dll" ]' "$OUT"

# ------------------------------------------------- CachyOS, proton-cachyos ----
section "CachyOS: proton-cachyos installed, nothing chosen for the game yet"
newworld cachy cachyos; OSR="$T/os-cachyos"
run check
expect "Steam's default reported"     '[[ "$OUT" == *"Proton for the game:"*"not chosen; Steam uses proton_10"* ]]' "$OUT"
run install --yes --proton nonexistent
expect "unknown --proton refused with the installed list" '[ $RC != 0 ] && [[ "$OUT" == *"no compatibility tool named"*"proton-cachyos-native, proton-cachyos-slr, proton_experimental"* ]]' "$OUT"
run install --yes
expect "proton-cachyos (Steam Linux Runtime build) chosen" '[ $RC = 0 ] && [ "$(tool)" = proton-cachyos-slr ] && [[ "$OUT" == *"steam linux runtime"* ]]' "$OUT"
run check
expect "check resolves Proton from the new setting" '[[ "$OUT" == *"Proton: proton-cachyos-slr"*"Steam setting \"proton-cachyos-slr\""* ]]' "$OUT"
expect "pacman hint for vm.max_map_count" '[[ "$OUT" != *"vm.max_map_count is"* ]] || [[ "$OUT" == *"sudo tee /etc/sysctl.d"* ]]' "$OUT"
run install --yes --proton experimental
expect "--proton experimental honoured" '[ $RC = 0 ] && [ "$(tool)" = proton_experimental ]' "$OUT"
run install --yes --proton keep
expect "--proton keep leaves the choice" '[ $RC = 0 ] && [ "$(tool)" = proton_experimental ] && [[ "$OUT" == *"left as it is (--proton keep)"* ]]' "$OUT"
run install --yes
expect "an explicit choice is respected" '[ "$(tool)" = proton_experimental ] && [[ "$OUT" == *"already chosen for this game"* ]]' "$OUT"

# ------------------------------------------------ patches before 2.5 ----
section "Game patch 2.31: older than 2.5, no longer supported"
newworld g231 native 2.31; OSR="$T/os-cachyos"
BEFORE="$(snapshot "$H")"
run install --yes
expect "install refuses a game older than 2.5, changing nothing" '[ $RC != 0 ] && [[ "$OUT" == *"older than patch 2.5, the oldest this installer supports"* ]] && [ "$BEFORE" = "$(snapshot "$H")" ]' "$OUT"
run check
expect "check says so too" '[ $RC = 0 ] && [[ "$OUT" == *"game 2.31 is older than patch 2.5"* ]]' "$OUT"

# --------------------------------------- old single archive, game 2.5 ----
section "Old single NightCoop archive (bundles RED4ext 1.30) on game 2.5"
newworld old native; OSR="$T/os-arch"
run install --yes --nightcoop-zip "$FIX/site/dl/0.1.1-beta.2/NightCoop-0.1.1-beta.2.zip"
expect "archive identified by checksum" '[ $RC = 0 ] && [[ "$OUT" == *"archive verified: NightCoop 0.1.1-beta.2"* ]]' "$OUT"
expect "RED4ext 1.31 replaces the bundled 1.30" '[ "$(hp pever "$G/red4ext/RED4ext.dll" product)" = 1.31.0 ] && [ "$(hp pever "$G/bin/x64/winmm.dll" product)" = 1.31.0 ] && [[ "$OUT" == *"RED4ext 1.31.0 archive verified"* ]]' "$OUT"
expect "README in the archive's top folder not copied" '[ ! -e "$G/README.txt" ] && [ -f "$G/red4ext/Plugins/NightCoop/NightCoop.dll" ]'
run check
expect "check offers the newer build" '[[ "$OUT" == *"NightCoop update:"*"0.1.1-beta.2 -> 0.2.0-beta available"* ]]' "$OUT"
run update --yes
expect "update installs the site's newer build" '[ $RC = 0 ] && [ "$(hp pever "$G/red4ext/Plugins/NightCoop/NightCoop.dll")" = 0.2.0.0 ] && [[ "$OUT" == *"update          NightCoop 0.1.1-beta.2 -> 0.2.0-beta"* ]]' "$OUT"
expect "an update leaves the saves to the first copy" '[[ "$OUT" == *"not copied on an update"* ]] && [ ! -e "$(newest_backup)Saved Games" ]' "$OUT"
expect "check after the update: nothing newer" '[[ "$OUT" == *"NightCoop update:"*"none; 0.2.0-beta is the latest for game 2.5"* ]]' "$OUT"
run restore --yes
run check
expect "restore puts the record back to the earlier build" '[ "$(hp pever "$G/red4ext/Plugins/NightCoop/NightCoop.dll")" = 0.1.1.0 ] && [[ "$OUT" == *"release 0.1.1-beta.2"* ]] && [[ "$OUT" == *"0.1.1-beta.2 -> 0.2.0-beta available"* ]]' "$OUT"

# ------------------------------------------------------- updating in place ----
section "Updating in place"
newworld upd native; OSR="$T/os-arch"
REC="$H/.local/share/nightcoop-linux/installed.tsv"
run install --yes
expect "first install copies the saves" '[ $RC = 0 ] && [ -f "$(newest_backup)Saved Games/ManualSave-0/sav.dat" ]' "$OUT"
B1="$(newest_backup)"; G1="$(snapshot "$G")"
rm "$REC"
run check
expect "check without a record suggests an update run" '[[ "$OUT" == *"NightCoop update:"*"is 0.2.0-beta; run"*" update"*"to make sure it is the one installed"* ]]' "$OUT"
run install --yes
expect "files that already match are recorded, not replaced" '[ $RC = 0 ] && [[ "$OUT" == *"recorded as the installed build"* ]] && [ "$(newest_backup)" = "$B1" ] && grep -qx "version"$'"'"'\t'"'"'"0.2.0-beta" "$REC"' "$OUT"
cp "$FIX/pe/nc2/NightCoop.dll" "$G/red4ext/Plugins/NightCoop/NightCoop.dll"
run check
expect "check notices a NightCoop.dll copied in by hand" '[[ "$OUT" == *"NightCoop:"*"0.2.1.0"*"changed since this script installed 0.2.0-beta"* ]]' "$OUT"
run update --yes
expect "the update replaces only the file that differs" '[ $RC = 0 ] && [[ "$OUT" == *"0 added, 1 replaced, 0 stale removed"* ]] && [ "$G1" = "$(snapshot "$G")" ]' "$OUT"
expect "the plan says the recorded build was changed" '[[ "$OUT" == *"update          NightCoop 0.2.0-beta, changed since it was installed -> 0.2.0-beta"* ]]' "$OUT"
expect "the saves are not copied again" '[[ "$OUT" == *"not copied on an update"* ]] && [ ! -e "$(newest_backup)Saved Games" ]' "$OUT"
run update --yes --force --backup-saves
expect "--force replaces every file, --backup-saves copies the saves" '[ $RC = 0 ] && [[ "$OUT" == *", 0 unchanged; backup"* ]] && [ -f "$(newest_backup)Saved Games/ManualSave-0/sav.dat" ]' "$OUT"
mkdir -p "$H/.local/share/nightcoop-linux/backups/2099-01-01-000000/game"   # an install stopped while copying the saves
run restore --yes
expect "an interrupted backup is passed over" '[ $RC = 0 ] && [[ "$OUT" != *"2099-01-01-000000"* ]] && [ -f "$G/red4ext/Plugins/OtherMod/other.dll" ] && [ -f "$G/red4ext/RED4ext.dll" ]' "$OUT"
run restore --yes
run check
expect "after undoing the repair, the hand-copied DLL is told apart again" '[[ "$OUT" == *"NightCoop:"*"0.2.1.0"*"changed since this script installed 0.2.0-beta"* ]]' "$OUT"

# ------------------------------------------------- Let There Be Flight ----
section "Let There Be Flight (--with-flight)"
newworld fly native; OSR="$T/os-arch"
P="$G/red4ext/Plugins"; PRISTINE_FLY="$(snapshot "$G")"
fver() { hp pever "$1" | cut -d. -f1-3; }
run install --yes --without-flight
expect "without the option, the set is only suggested" '[ $RC = 0 ] && [[ "$OUT" == *"Let There Be Flight:"*"not installed; NightCoop supports it in co-op (add --with-flight)"* ]] && [[ "$OUT" == *"Add --with-flight"* ]] && [ ! -e "$P/let_there_be_flight" ]' "$OUT"
expect "--without-flight with nothing to remove says so" '[[ "$OUT" == *"has not installed Let There Be Flight; nothing to remove"* ]]' "$OUT"
BEFORE="$(snapshot "$H")"
run install --dry-run --with-flight
expect "a dry run with the set changes nothing, not even the cache" '[ $RC = 0 ] && [[ "$OUT" == *"dry run finished"* ]] && [ "$BEFORE" = "$(snapshot "$H")" ]' "$OUT"
run install --yes --with-flight
expect "--with-flight installs the set paired with game 2.5" '[ $RC = 0 ] && [ "$(fver "$P/let_there_be_flight/let_there_be_flight.dll")" = 0.3.20 ] && [ "$(fver "$P/ArchiveXL/ArchiveXL.dll")" = 1.28.6 ] && [ "$(fver "$P/TweakXL/TweakXL.dll")" = 1.12.0 ] && [ "$(fver "$P/input_loader/input_loader.dll")" = 0.2.6 ] && grep -q "redscript lib 0.5.32" "$G/engine/tools/scc_lib.dll"' "$OUT"
expect "the plan lists the set" '[[ "$OUT" == *"add-ons         redscript 0.5.32, ArchiveXL 1.28.6, TweakXL 1.12.0, Input Loader 0.2.6, Let There Be Flight 0.3.20 (for game 2.5)"* ]]' "$OUT"
expect "game files the set replaces are backed up" '[ "$(cat "$(newest_backup)game/engine/tools/scc.exe")" = "the game'"'"'s own script compiler" ] && [ -f "$(newest_backup)game/r6/cache/inputContexts.xml" ]' "$OUT"
expect "check lists the set by release" '[[ "$OUT" == *"Let There Be Flight:"*"0.3.20, with redscript 0.5.32, ArchiveXL 1.28.6, TweakXL 1.12.0, Input Loader 0.2.6 (kept up to date by this script)"* ]]' "$OUT"
B1="$(newest_backup)"
run update --yes
expect "the choice is remembered; a rerun changes and downloads nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]] && [ "$(newest_backup)" = "$B1" ] && [[ "$OUT" != *"downloading"* ]]' "$OUT"
cp "$FIX/pe/axl-1.28.7/ArchiveXL.dll" "$P/ArchiveXL/ArchiveXL.dll"
run update --yes
expect "a newer ArchiveXL for the same patch, installed by hand, is kept" '[ $RC = 0 ] && [[ "$OUT" == *"keeping the installed ArchiveXL 1.28.7"* ]] && [ "$(fver "$P/ArchiveXL/ArchiveXL.dll")" = 1.28.7 ] && [ -f "$P/ArchiveXL/Scripts/ArchiveXL.reds" ]' "$OUT"
cp "$FIX/pe/Cyberpunk2077-2.6.exe" "$G/bin/x64/Cyberpunk2077.exe"   # a patch newer than the tables
FLY_ADDONS="$(cd "$G" && find red4ext/Plugins/let_there_be_flight red4ext/Plugins/ArchiveXL engine/tools -type f | sort | xargs sha256sum)"
run update --yes
expect "on a patch the tables do not know, the set is left as it is" '[ $RC = 0 ] && [[ "$OUT" == *"no add-on builds are known for game 2.6; what is installed is left as it is"* ]] && [ "$FLY_ADDONS" = "$(cd "$G" && find red4ext/Plugins/let_there_be_flight red4ext/Plugins/ArchiveXL engine/tools -type f | sort | xargs sha256sum)" ]' "$OUT"
cp "$FIX/pe/Cyberpunk2077-2.5.exe" "$G/bin/x64/Cyberpunk2077.exe"
run update --yes --without-flight
expect "--without-flight removes Let There Be Flight, folder and all" '[ $RC = 0 ] && [ ! -e "$P/let_there_be_flight" ]' "$OUT"
expect "the mods it needed stay" '[ -f "$P/ArchiveXL/ArchiveXL.dll" ] && [ -f "$P/TweakXL/TweakXL.dll" ] && [ -f "$P/input_loader/input_loader.dll" ] && [ -f "$G/engine/tools/scc_lib.dll" ]' "$OUT"
run update --yes
expect "and stay on the next run too" '[ $RC = 0 ] && [ -f "$P/ArchiveXL/ArchiveXL.dll" ] && [ -f "$G/engine/tools/scc_lib.dll" ]' "$OUT"
run check
expect "check shows Let There Be Flight off again" '[[ "$OUT" == *"Let There Be Flight:"*"not installed; NightCoop supports it in co-op"* ]]' "$OUT"
cp "$FIX/pe/Cyberpunk2077-2.5.exe" "$G/bin/x64/Cyberpunk2077.exe"
run uninstall --yes
expect "uninstall puts the game folder back exactly, the game's own files included" '[ $RC = 0 ] && [ "$PRISTINE_FLY" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_FLY") <(snapshot "$G"))"
newworld flybad native; OSR="$T/os-arch"
Z="$FIX/gh/TweakXL-1.12.0.zip"; cp "$Z" "$T/good.zip"; printf 'x' >> "$Z"
BEFORE="$(snapshot "$G")"
run install --yes --with-flight
cp "$T/good.zip" "$Z"
expect "an archive that does not match its SHA-256 is refused before anything changes" '[ $RC != 0 ] && [[ "$OUT" == *"SHA-256 mismatch for TweakXL-1.12.0.zip"* ]] && [ "$BEFORE" = "$(snapshot "$G")" ]' "$OUT"

# ----------------------------------------------------------------- mods ----
section "Mods (--with-mods): Virtual Atelier and its stores, Virtual Car Dealer, Drive an Aerial Vehicle, Cyber Drift and more"
newworld mods native; OSR="$T/os-arch"
D="$H/Downloads"; mkdir -p "$D"; NX="$FIX/nexus"
P="$G/red4ext/Plugins"; CETM="$G/bin/x64/plugins/cyber_engine_tweaks/mods"; DAV="$CETM/DriveAerialVehicle"; PRISTINE_MODS="$(snapshot "$G")"
# The first downloads: Virtual Atelier as Nexus names files since 2026 (a second copy, as the browser names it)
# and its last Basic file (2024); both files of No Intro Videos; Cyber Drift's Light file, a newer one that is not
# Light, and its 2.3 file
cp "$NX/Virtual Atelier - Basic-2987-1-2-4-1706771312.zip" \
   "$NX/No Intro Videos-533-0-5-1721546294.zip" "$NX/No Intro Videos - redscript-533-0-8-1760416944.zip" \
   "$NX/CyberDrift 2.0 Light for game ver. 2.31 8306 2.31 2026-08-03T18-29Z 4rpqrKU17.zip" \
   "$NX/Cyber Drift 2.0 for game ver. 2.5 8306 2.5 2026-11-03T10-00Z Rq4tLm9Wx.zip" \
   "$NX/Cyber Drift for game 2.3 TweakXL-8306-2-3-1754137206.zip" "$D/"
cp "$NX/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$D/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7 (1).zip"
# xdg-user-dir names the home folder when no Downloads folder is set; ~/Downloads is used then
mkdir -p "$T/xdg-unset" "$T/xdg-fr"
printf '#!/bin/sh\necho "$HOME"\n' > "$T/xdg-unset/xdg-user-dir"; printf '#!/bin/sh\necho "$HOME/T\303\251l\303\251chargements"\n' > "$T/xdg-fr/xdg-user-dir"
chmod +x "$T/xdg-unset/xdg-user-dir" "$T/xdg-fr/xdg-user-dir"
PATH="$T/xdg-unset:$PATH" run install --yes --with-mods
expect "the frameworks come from GitHub, Mod Settings and Audioware among them" '[ $RC = 0 ] && [ "$(fver "$G/bin/x64/plugins/cyber_engine_tweaks.asi")" = 1.38.1 ] && [ -f "$G/bin/x64/version.dll" ] && [ "$(fver "$P/Codeware/Codeware.dll")" = 1.21.2 ] && [ -f "$P/TweakXL/TweakXL.dll" ] && [ -f "$P/ArchiveXL/ArchiveXL.dll" ] && grep -q "redscript lib 0.5.32" "$G/engine/tools/scc_lib.dll" && [ "$(fver "$P/mod_settings/mod_settings.dll")" = 0.2.28 ] && [ -f "$P/audioware/audioware.dll" ]' "$OUT"
expect "Cyber Engine Tweaks loads from the first run: its override is set" '[ "$(hp reg-get "$PFX/user.reg" "$REG_KEY" version)" = native,builtin ] && [[ "$(launch_opts)" == *"winmm,version=n,b"* ]]' "$(launch_opts)"
expect "Virtual Atelier as Nexus names files since 2026 (a browser's second copy), not its 2024 Basic file" '[ -f "$G/r6/scripts/virtual-atelier-full/Config.reds" ] && [ ! -e "$G/r6/scripts/VirtualAtelier" ]' "$OUT"
expect "No Intro Videos: the archive file, never the redscript one" '[ -f "$G/archive/pc/mod/NoIntroVideos.archive" ] && [ ! -e "$G/r6/scripts/NoIntroVideos" ]' "$OUT"
expect "Cyber Drift: the Light file, over a newer full one and the one for 2.3" '[ -f "$CETM/CyberDrift Light/init.lua" ] && [ ! -e "$CETM/CyberDrift" ] && [ ! -e "$G/r6/tweaks/CyberDrift" ] && [[ "$OUT" != *"does not look like the light file"* ]]' "$OUT"
expect "what is not downloaded yet is listed with its Nexus page" '[[ "$OUT" == *"A.G.I.S. (the main file, PUBLICNET): https://www.nexusmods.com/cyberpunk2077/mods/10909?tab=files"* ]] && [[ "$OUT" == *"Night City Marketplace: https://www.nexusmods.com/cyberpunk2077/mods/4433?tab=files"* ]] && [[ "$OUT" == *"Quick Stash: https://www.nexusmods.com/cyberpunk2077/mods/30016?tab=files"* ]] && [[ "$OUT" == *"Native Settings UI: https://www.nexusmods.com/cyberpunk2077/mods/3518?tab=files"* ]] && [[ "$OUT" == *"Virtual Car Dealer: https://www.nexusmods.com/cyberpunk2077/mods/4454?tab=files"* ]] && [[ "$OUT" == *"Drive an Aerial Vehicle: https://www.nexusmods.com/cyberpunk2077/mods/13842?tab=files"* ]]' "$OUT"
run check
expect "check lists the mods and what is missing" '[[ "$OUT" == *"Mods:"*"Virtual Atelier 1.6.4, No Intro Videos 0.5, Cyber Drift 2.31, with redscript 0.5.32, ArchiveXL 1.28.6, TweakXL 1.12.0, Codeware 1.21.2, Cyber Engine Tweaks 1.38.1, Mod Settings 0.2.28, Audioware 1.11.1 (kept up to date by this script)"* ]] && [[ "$OUT" == *"missing: Native Settings UI, A.G.I.S., Night City Marketplace, Virtual Car Dealer, Quick Stash, Drive an Aerial Vehicle"* ]]' "$OUT"
find "$D" -maxdepth 1 -type f -delete   # the Downloads folder cleaned up: the installer kept its own copies
cp "$NX/PUBLICNET-10909-1-2-1-1702220953.zip" "$NX/BLACKWALL-10909-1-2-1-1702221109.zip" "$NX/Darks Night City Marketplace-4433-2-3-0-1757877636.zip" \
   "$NX/Quick Stash-30016-v1-1-1779816414.zip" "$NX/Virtual Car Dealer 4454 2.3.0 2026-10-25T11-18Z lcXrcZZMt.zip" \
   "$NX/Native Settings UI 1.97 3518 1.97 2026-10-22T15-26Z cB3xB00Va.zip" "$NX/Drive an Aerial Vehicle 13842 3.5.0 2026-10-26T16-09Z mPgaPVV1e.zip" "$D/"
run update --yes
expect "the rest install once downloaded: A.G.I.S.'s main file, out of its folder, without its read-me" '[ $RC = 0 ] && [ -f "$G/r6/scripts/AGIS/agis.reds" ] && [ ! -e "$G/r6/scripts/AGIS_BLACKWALL" ] && [ ! -e "$G/readme.txt" ] && [ ! -e "$G/AGIS" ] && [ -f "$G/r6/scripts/NCMarketplace/stores.reds" ] && [ -f "$CETM/QuickStash/init.lua" ] && [ -f "$G/r6/scripts/VirtualCarDealer/core/CarDealer-System.reds" ] && [ -f "$CETM/nativeSettings/init.lua" ] && [ -f "$DAV/init.lua" ] && [ -f "$P/DriveAerialVehicle/DriveAerialVehicle.dll" ]' "$OUT"
expect "the mods downloaded first stay, from the installer's own copies" '[ -f "$G/r6/scripts/virtual-atelier-full/Config.reds" ] && [ -f "$CETM/CyberDrift Light/init.lua" ] && [[ "$OUT" != *"cyberpunk2077/mods/2987?tab=files"* ]]' "$OUT"
expect "co-op notes: Quick Stash, and cars and AVs of mods" '[[ "$OUT" == *"a guest'"'"'s stash there is not their own"* ]] && [[ "$OUT" == *"otherwise NightCoop shows a game car with as many seats"* ]]' "$OUT"
B1="$(newest_backup)"
run update --yes
expect "with everything downloaded and in place, a rerun changes nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]] && [ "$(newest_backup)" = "$B1" ]' "$OUT"
# Playing: Drive an Aerial Vehicle saves its settings and learns the map; Cyber Drift's car list is edited
printf '{"language": "jp-jp"}\n' > "$DAV/Data/user_setting_v3.json"; printf 'learned 0 0' > "$DAV/Data/map_bin/chunk_0_0.bin"
printf 'learned 0 1' > "$DAV/Data/map_bin/chunk_0_1.bin"; printf '{"cars": ["mine"]}\n' > "$CETM/CyberDrift Light/custom/car_list.json"
printf 'SQLite format 3' > "$CETM/CyberDrift Light/db.sqlite3"
run update --yes
expect "files the mods write to while the game runs stay as the player has them" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]] && grep -q jp-jp "$DAV/Data/user_setting_v3.json" && grep -q "learned 0 0" "$DAV/Data/map_bin/chunk_0_0.bin" && grep -q mine "$CETM/CyberDrift Light/custom/car_list.json" && grep -q SQLite "$CETM/CyberDrift Light/db.sqlite3"' "$OUT"
cp "$FIX/nexus-later/Drive an Aerial Vehicle 13842 3.5.1 2026-11-02T09-30Z Zx81kQp0a.zip" "$D/"
run update --yes
expect "a new release replaces only what it changed: the settings stay, its new map file comes in (backed up)" '[ $RC = 0 ] && grep -q jp-jp "$DAV/Data/user_setting_v3.json" && grep -q "map 0 0 v2" "$DAV/Data/map_bin/chunk_0_0.bin" && grep -q "learned 0 1" "$DAV/Data/map_bin/chunk_0_1.bin" && [ "$(cat "$(newest_backup)game/bin/x64/plugins/cyber_engine_tweaks/mods/DriveAerialVehicle/Data/map_bin/chunk_0_0.bin")" = "learned 0 0" ]' "$OUT"
cp "$FIX/nexus-bad/No Intro Videos-533-0-6-1730000000.zip" "$D/"
run update --yes
expect "a newer download without game folders is passed over for the copy that works" '[ $RC = 0 ] && [[ "$OUT" == *"No Intro Videos-533-0-6-1730000000.zip has no game folders"* ]] && [[ "$OUT" != *"none of its downloads can be used"* ]] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]] && [ -f "$G/archive/pc/mod/NoIntroVideos.archive" ]' "$OUT"
rm "$H/.cache/nightcoop-linux/mods/No Intro Videos-533-0-5-1721546294.zip"   # no good copy left
printf 'not a zip' > "$D/No Intro Videos-533-0-7-1740000000.zip"
run update --yes
expect "with no usable download at all, the installed copy stays" '[ $RC = 0 ] && [[ "$OUT" == *"could not unpack No Intro Videos-533-0-7-1740000000.zip: not a usable zip archive"* ]] && [[ "$OUT" == *"keeping the installed No Intro Videos: none of its downloads can be used"* ]] && [ -f "$G/archive/pc/mod/NoIntroVideos.archive" ]' "$OUT"
rm "$D/No Intro Videos-533-0-6-1730000000.zip" "$D/No Intro Videos-533-0-7-1740000000.zip"
run update --yes --with-flight
expect "both sets: the shared frameworks once, Let There Be Flight added" '[ $RC = 0 ] && [ -f "$P/let_there_be_flight/let_there_be_flight.dll" ] && [[ "$OUT" == *"Add-ons: flight, mods"* ]]' "$OUT"
run update --yes --without-mods
expect "--without-mods removes the mods, those inside Cyber Engine Tweaks' folder too" '[ $RC = 0 ] && [ ! -e "$G/r6/scripts/virtual-atelier-full" ] && [ ! -e "$G/r6/scripts/AGIS" ] && [ ! -e "$G/r6/scripts/VirtualCarDealer" ] && [ ! -e "$CETM/QuickStash" ] && [ ! -e "$G/archive/pc/mod/NoIntroVideos.archive" ] && [ ! -e "$CETM/CyberDrift Light" ] && [ ! -e "$DAV" ] && [ ! -e "$P/DriveAerialVehicle" ]' "$OUT"
expect "the frameworks stay, and the flight set keeps its own" '[ -f "$G/bin/x64/plugins/cyber_engine_tweaks.asi" ] && [ -f "$G/bin/x64/plugins/cyber_engine_tweaks/scripts/autoexec.lua" ] && [ -f "$P/Codeware/Codeware.dll" ] && [ -f "$P/TweakXL/TweakXL.dll" ] && [ -f "$P/mod_settings/mod_settings.dll" ] && [ -f "$P/audioware/audioware.dll" ] && [ -f "$CETM/nativeSettings/init.lua" ] && [ -f "$P/let_there_be_flight/let_there_be_flight.dll" ]' "$OUT"
run check
expect "check: the flight set still kept up to date, the mods no longer" '[[ "$OUT" == *"Let There Be Flight:"*"0.3.20, with redscript 0.5.32, ArchiveXL 1.28.6, TweakXL 1.12.0, Input Loader 0.2.6 (kept up to date"* ]] && [[ "$OUT" == *"Mods:"*"not installed by this script (add --with-mods)"* ]]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_MODS" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_MODS") <(snapshot "$G"))"
newworld modsneeds native; OSR="$T/os-arch"; D="$H/Téléchargements"; mkdir -p "$D"   # a French desktop's Downloads folder
cp "$NX/PUBLICNET-10909-1-2-1-1702220953.zip" "$NX/Virtual Atelier - Basic-2987-1-2-4-1706771312.zip" "$NX/No Intro Videos - redscript-533-0-8-1760416944.zip" \
   "$NX/Drive an Aerial Vehicle 13842 3.5.0 2026-10-26T16-09Z mPgaPVV1e.zip" "$NX/Cyber Drift 2.0 for game ver. 2.31 8306 2.31 2026-07-03T23-03Z ymA1m8KJ2.zip" "$D/"
PATH="$T/xdg-fr:$PATH" run install --yes --with-mods
expect "a download too old for the game patch is passed over, saying why" '[ $RC = 0 ] && [ ! -e "$G/r6/scripts/VirtualAtelier" ] && [[ "$OUT" == *"Virtual Atelier - Basic-2987-1-2-4-1706771312.zip is Virtual Atelier 1.2.4; game 2.5 needs 1.6.4 or newer"* ]]' "$OUT"
expect "the redscript file of No Intro Videos is not installed, saying why and what to take" '[ ! -e "$G/r6/scripts/NoIntroVideos" ] && [[ "$OUT" == *"is not installed: it is the redscript file of No Intro Videos"* ]] && [[ "$OUT" == *"No Intro Videos (the archive file): https://www.nexusmods.com/cyberpunk2077/mods/533?tab=files"* ]]' "$OUT"
expect "a store without Virtual Atelier is left out (it would stop every script compiling)" '[ ! -e "$G/r6/scripts/AGIS" ] && [[ "$OUT" == *"A.G.I.S. needs Virtual Atelier, which is not here"* ]] && [[ "$OUT" == *"Virtual Atelier: https://www.nexusmods.com/cyberpunk2077/mods/2987?tab=files"* ]]' "$OUT"
expect "Drive an Aerial Vehicle without Native Settings UI is left out" '[ ! -e "$G/bin/x64/plugins/cyber_engine_tweaks/mods/DriveAerialVehicle" ] && [[ "$OUT" == *"Drive an Aerial Vehicle needs Native Settings UI, which is not here"* ]]' "$OUT"
expect "Cyber Drift's other file is used when the Light one is not there, with a warning" '[ -f "$G/bin/x64/plugins/cyber_engine_tweaks/mods/CyberDrift/init.lua" ] && [[ "$OUT" == *"does not look like the light file of Cyber Drift; using it anyway"* ]]' "$OUT"
cp "$NX/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$D/Virtual_Atelier_2987_1.6.4_2026-10-25T17-42Z_HncQn22j7.zip"   # saved with underscores
PATH="$T/xdg-fr:$PATH" run update --yes
expect "a download saved with underscores for spaces is recognised, and the store follows" '[ $RC = 0 ] && [ -f "$G/r6/scripts/virtual-atelier-full/Config.reds" ] && [ -f "$G/r6/scripts/AGIS/agis.reds" ]' "$OUT"
newworld mods7z native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$T/niv7z"
python3 -I -m zipfile -e "$FIX/nexus/No Intro Videos-533-0-5-1721546294.zip" "$T/niv7z"
if command -v bsdtar >/dev/null 2>&1; then   # Arch, CachyOS and SteamOS have it (pacman needs libarchive)
    ln -s /etc/hostname "$T/niv7z/archive/pc/mod/elsewhere"
    bsdtar --format 7zip -cf "$D/No Intro Videos-533-0-5-1721546294.7z" -C "$T/niv7z" archive
    run install --yes --with-mods
    expect "a 7z download is unpacked with bsdtar, without the links in it (nor what they point to)" '[ $RC = 0 ] && [ -f "$G/archive/pc/mod/NoIntroVideos.archive" ] && [ ! -e "$G/archive/pc/mod/elsewhere" ] && [ ! -L "$G/archive/pc/mod/elsewhere" ]' "$OUT"
else
    printf '7z\274\257\047\034' > "$D/No Intro Videos-533-0-5-1721546294.7z"
    run install --yes --with-mods
    expect "without bsdtar, a 7z download is left out, saying why, and the rest installs" '[ $RC = 0 ] && [[ "$OUT" == *"a .7z archive needs bsdtar (from libarchive) to unpack"* ]] && [[ "$OUT" == *"No Intro Videos is left out"* ]] && [ ! -e "$G/archive/pc/mod/NoIntroVideos.archive" ] && [ -f "$G/bin/x64/plugins/cyber_engine_tweaks.asi" ]' "$OUT"
fi

section "Mods (--with-mods): clothing stores and outfits, car and bike packs, Vehicle Customizer"
newworld style native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
P="$G/red4ext/Plugins"; VC="$G/bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCustomizerSVE"; PRISTINE_STYLE="$(snapshot "$G")"
cp "$FIX/nexus/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$FIX/nexus/Virtual Car Dealer 4454 2.3.0 2026-10-25T11-18Z lcXrcZZMt.zip" "$FIX"/style/* "$D/"
run install --yes --with-mods
expect "the clothing stores, and the Zenitex outfits by their main files only (no Alt. Colors, GS or Gymfiend file)" '[ $RC = 0 ] && [ -f "$G/r6/scripts/AllVanillaClothes/store.reds" ] && [ -f "$G/r6/scripts/iconicshop/shops/top.reds" ] && [ -f "$G/r6/scripts/ScorpionTank/scorpion_zenitex_virtual_atelier.reds" ] && ( for i in mask harness jacket pads pants gloves; do [ -f "$G/r6/tweaks/scorpiontank/zenitex_$i.yaml" ] && [ ! -e "$G/r6/tweaks/scorpiontank/zenitex_${i}_gs.yaml" ] || exit 1; done ) && [ ! -e "$G/r6/tweaks/scorpiontank/zenitex_mask_alt.yaml" ] && [ -f "$G/r6/tweaks/scorpiontank/comfy_boots.yaml" ] && [ ! -e "$G/r6/tweaks/scorpiontank/comfy_boots_gymfiend.yaml" ] && [ ! -e "$G/codes.txt" ]' "$OUT"
expect "both car packs of one Nexus mod, the bikes' main file only, the Supra and the Porsche with what they need" '[ -f "$G/r6/tweaks/VirtualCarDealer/car_pack_1.yaml" ] && [ -f "$G/r6/tweaks/VirtualCarDealer/car_pack_2.yaml" ] && [ -f "$G/r6/tweaks/Methodd/Methodd_Edge/mthdd_Methodd_Edge.yaml" ] && [ -f "$G/archive/pc/mod/BDF_DRe_ArchV4.archive" ] && [ ! -e "$G/archive/pc/mod/BDF_DRe_ArchV4_Mirrors.archive" ] && [ ! -e "$G/archive/pc/mod/dre_cyberhelmets.archive" ] && [ -f "$G/r6/tweaks/VehicleExitFix/exit.yaml" ] && [ -f "$G/r6/tweaks/krnlnik/supra.yaml" ] && [ ! -e "$G/r6/tweaks/krnlnik/supra_colors.yaml" ] && [ -f "$G/r6/scripts/VMF/vmf.reds" ] && [ -f "$G/archive/pc/mod/porsche_gt3rs.archive" ] && [ ! -e "$G/archive/pc/mod/porsche_gt3rs_grey_red.archive" ] && [ -f "$G/archive/pc/mod/MaterialTextureOverride.archive" ] && [ ! -e "$G/mods/MaterialTextureOverride" ]' "$OUT"
expect "Vehicle Customizer: its 3.1 update on top of 3.0" '[ "$(cat "$VC/init.lua")" = "-- vehicle customizer 3.1" ] && [ -f "$VC/data/appearances.json" ]' "$OUT"
expect "co-op notes: outfits of mods, and Vehicle Customizer's language" '[[ "$OUT" == *"a partner without the same outfit mod sees a plain game piece"* ]] && [[ "$OUT" == *"Vehicle Customizer works only with the game'"'"'s language set to English"* ]]' "$OUT"
printf '{"Quadra": "b"}\n' > "$VC/saved.json"   # a customisation saved while playing
run update --yes
expect "Vehicle Customizer's saved customisations stay; a rerun changes nothing" '[ $RC = 0 ] && grep -q Quadra "$VC/saved.json" && [ "$(cat "$VC/init.lua")" = "-- vehicle customizer 3.1" ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run update --yes --without-mods
expect "--without-mods removes the clothing and vehicles; Material and Texture Override stays as a framework" '[ $RC = 0 ] && [ ! -e "$G/r6/scripts/iconicshop" ] && [ ! -e "$G/r6/tweaks/scorpiontank" ] && [ ! -e "$G/r6/tweaks/VirtualCarDealer" ] && [ ! -e "$G/archive/pc/mod/porsche_gt3rs.archive" ] && [ ! -e "$VC" ] && [ -f "$G/archive/pc/mod/MaterialTextureOverride.archive" ]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_STYLE" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_STYLE") <(snapshot "$G"))"
newworld stylepack native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
cp "$FIX/nexus/Virtual Car Dealer 4454 2.3.0 2026-10-25T11-18Z lcXrcZZMt.zip" "$FIX/style/Virtual Car Dealer - Car Pack 2-4625-1-9-0-1675361670.zip" "$D/"
run install --yes --with-mods
expect "one file of a mod with two: Car Pack 2 installs, Car Pack 1 is listed, without a word about the other's file" '[ $RC = 0 ] && [ -f "$G/r6/tweaks/VirtualCarDealer/car_pack_2.yaml" ] && [[ "$OUT" == *"Vehicle Pack Basic 1 (Car Pack 1): https://www.nexusmods.com/cyberpunk2077/mods/4625?tab=files"* ]] && [[ "$OUT" != *"Car Pack 2-4625-1-9-0-1675361670.zip is not installed"* ]]' "$OUT"
cp "$FIX/style/Vehicle Customizer SVE 3dot1 9034 3.1 2026-09-21T11-33Z tvQTvsQ74.zip" "$D/"
run update --yes
expect "an update file alone is not taken for its main file: the update waits for it" '[ $RC = 0 ] && [ ! -e "$G/bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCustomizerSVE" ] && [[ "$OUT" == *"Vehicle Customizer update needs Vehicle Customizer, which is not here"* ]] && [[ "$OUT" == *"Vehicle Customizer (SVE 3dot0, among the main files): https://www.nexusmods.com/cyberpunk2077/mods/9034?tab=files"* ]]' "$OUT"

# ------------------------------------- the third round, and Equipment-EX ----
section "Mods (--with-mods): six cars, the clothes of three stores, Impact FX, Immersive Audio Distance; Equipment-EX"
newworld round3 native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
PRISTINE_R3="$(snapshot "$G")"
cp "$FIX/nexus/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$FIX/nexus/Virtual Car Dealer 4454 2.3.0 2026-10-25T11-18Z lcXrcZZMt.zip" "$FIX"/round3/* "$D/"
# the GR Yaris's drift tune as a later release, newer than the main file: the rule still takes the main file
cp "$FIX/round3/Toyota Yaris GR Drift Handling Spec (Tune Only) 34357 1 2026-10-29T18-57Z Co8doe62d.zip" "$D/Toyota Yaris GR Drift Handling Spec (Tune Only) 34357 3.4 2026-11-20T09-00Z Co8doe62e.zip"
came() { grep -q -F -- "$2" "$G/$1" 2>/dev/null; }   # came <file> <part of a download's name>: the file is that download's
run install --yes --with-mods
expect "the six cars: the GR Yaris's main file and kit, not its drift tune (a newer release of it too); the Silvia with what it needs, not its second livery" '[ $RC = 0 ] && [ -f "$G/r6/tweaks/xaires/apollo_ie.yaml" ] && [ -f "$G/r6/tweaks/xaires/countach.yaml" ] && [ -f "$G/r6/tweaks/xaires/countach_lbwk.yaml" ] && [ -f "$G/r6/tweaks/FIGI6_Oka/vaz1111_oka.yaml" ] && came r6/tweaks/toyota_gr_yaris/toyota_gr_yaris.yaml "All Purpose" && [ -f "$G/archive/pc/mod/00_Toyota_Yaris_GR_RocketBunny.archive" ] && [ -f "$G/r6/tweaks/ctrlsec/ctrlsec_UnboundS14_Nomad.yaml" ] && [ ! -e "$G/archive/pc/mod/Livery_2.archive" ] && [ -f "$G/archive/pc/mod/car_manuf.archive" ]' "$OUT"
expect "Impact FX, and Immersive Audio Distance's file for 2.5, not the one for 2.31" '[ -f "$G/r6/scripts/CinematicImpactFX/CinematicImpactFX.reds" ] && came "r6/scripts/Immersive Audio Distance/ImmersiveAudioDistance.reds" "Immersive Voice Distance (2.5)"' "$OUT"
expect "The RVC00N Dumpster 3 with VendorsXL and Deceptious Quest Core; its garments, the Fifth Element's all-in-one file and Dexter's three" '[ -f "$G/r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_TheRVC00NDumpster3.yaml" ] && [ -f "$G/r6/scripts/VendorsXL/VendorsXL.reds" ] && [ -f "$G/archive/pc/mod/zDeceptiousQuestCore.archive" ] && [ -f "$G/r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_GoliathCoat.yaml" ] && [ -f "$G/r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_KnifeBandolier.yaml" ] && came archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooPants.archive "ALL IN ONE" && ( for p in pants vest shoes; do [ -f "$G/r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_DexterFit_$p.yaml" ] || exit 1; done )' "$OUT"
expect "Street Ninja's store and clothes, Nola Dreamer's store and accessories; not the photo-mode clothes of Veegee and Dolly Go-Go, though downloaded; no read-me, code list or PDF in the game folder" '[ ! -e "$G/r6/scripts/veegee_shop_3.reds" ] && [ ! -e "$G/Veegee Shop 3" ] && [ ! -e "$G/r6/tweaks/Veegee" ] && [ ! -e "$G/r6/tweaks/fairyexe" ] && [[ "$OUT" != *"Veegee"* ]] && [[ "$OUT" != *"Dolly"* ]] && [ -f "$G/r6/tweaks/StreetNinja20_Collection.yaml" ] && [ -f "$G/bin/x64/plugins/cyber_engine_tweaks/mods/StreetNinjaShopOrder/init.lua" ] && [ -f "$G/r6/scripts/ND_Accessories_store.reds" ] && [ -f "$G/r6/tweaks/nola_dreamer/ND_AirPods_Max_FemV.yaml" ] && [ -f "$G/r6/tweaks/nola_dreamer/ND_Spiked_Collar_BothV.yaml" ] && [ ! -e "$G/veegee_urban_techwear_outfit_code.txt" ] && [ ! -e "$G/StreetNinja20_Collection_README.txt" ] && [ ! -e "$G/StreetNinjaStreetwearShop_README.txt" ] && [ ! -e "$G/Street_Ninja_Remake_1.14.0_Item_Catalog.pdf" ]' "$OUT"
expect "Equipment-EX only when asked; co-op notes on outfits, layers and VendorsXL; the clothes no store sells" '[ ! -e "$G/r6/scripts/EquipmentEx" ] && [[ "$OUT" == *"a partner without the same outfit mod sees a plain game piece"* ]] && [[ "$OUT" == *"worn together with Equipment-EX"* ]] && [[ "$OUT" == *"VendorsXL changes how every vendor restocks"* ]] && [[ "$OUT" == *"No store of the set sells Nola Dreamer'"'"'s mini dress"* ]]' "$OUT"
run update --yes
expect "a rerun changes nothing, and names nothing as gone from the set" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]] && [[ "$OUT" != *"no longer part of the set"* ]]' "$OUT"
run update --yes --with-equipment-ex
expect "--with-equipment-ex adds its main file, not the Hide Hub Buttons patch, and says partners need it too" '[ $RC = 0 ] && [ -f "$G/r6/scripts/EquipmentEx/EquipmentEx.reds" ] && [ ! -e "$G/r6/scripts/EquipmentEx/EquipmentEx.HideHubButtons.reds" ] && [[ "$OUT" == *"Equipment-EX in co-op: every partner needs it too"* ]] && [[ "$OUT" != *"worn together with Equipment-EX"* ]]' "$OUT"
run check
expect "check: Equipment-EX is kept up to date" '[[ "$OUT" == *"Equipment-EX:"*"Equipment EX 1.2.10 (kept up to date by this script)"* ]]' "$OUT"
run update --yes --without-equipment-ex
expect "--without-equipment-ex takes it out again; the mods stay" '[ $RC = 0 ] && [ ! -e "$G/r6/scripts/EquipmentEx" ] && [ -f "$G/r6/tweaks/StreetNinja20_Collection.yaml" ]' "$OUT"
run update --yes --without-mods
expect "--without-mods removes the cars and clothes; VendorsXL, Deceptious Quest Core and Vehicle Manufacturers Resource stay" '[ $RC = 0 ] && [ ! -e "$G/r6/tweaks/xaires" ] && [ ! -e "$G/r6/tweaks/nola_dreamer" ] && [ ! -e "$G/r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_GoliathCoat.yaml" ] && [ -f "$G/r6/scripts/VendorsXL/VendorsXL.reds" ] && [ -f "$G/archive/pc/mod/zDeceptiousQuestCore.archive" ] && [ -f "$G/archive/pc/mod/car_manuf.archive" ]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_R3" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_R3") <(snapshot "$G"))"
newworld round3needs native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
cp "$FIX/nexus/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$FIX/round3/Goliath Coat "* "$FIX/round3/The RVC00N Dumpster 3 "* "$FIX/round3/Deceptious Quest Core "* "$D/"
run install --yes --with-mods
expect "without VendorsXL the RVC00N store waits and says why; its garment installs" '[ $RC = 0 ] && [ ! -e "$G/r6/scripts/PinkyDude_TheRVC00NDumpster3.reds" ] && [ -f "$G/r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_GoliathCoat.yaml" ] && [[ "$OUT" == *"RVC00N Dumpster 3 needs VendorsXL, which is not here"* ]] && [[ "$OUT" != *"No store of the set sells"* ]]' "$OUT"
newworld retired native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
PRISTINE_RT="$(snapshot "$G")"
cp "$FIX/nexus/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$FIX"/round3/* "$D/"
# an earlier table, with Veegee's photo-mode outfit and store, which the set no longer has
awk '{ print } /^ADDON_SETS="$/ { print "Urban_Techwear_Outfit 2.5 mods mod - - 1.0 nexus:25512"; print "Veegee_Shop_3 2.5 mods mod - - 1.5.2 nexus:18890" }' "$NI" > "$T/ni-earlier.sh"
NI_NOW="$NI"; NI="$T/ni-earlier.sh"; run install --yes --with-mods; NI="$NI_NOW"
expect "the earlier table installs Veegee's outfit and store" '[ $RC = 0 ] && [ -f "$G/r6/scripts/veegee_shop_3.reds" ] && [ -f "$G/r6/tweaks/Veegee/veegee_urban_techwear_outfit.yaml" ]' "$OUT"
run update --yes
expect "the next run takes out what left the set, says so, and keeps the rest" '[ $RC = 0 ] && [ ! -e "$G/r6/scripts/veegee_shop_3.reds" ] && [ ! -e "$G/r6/tweaks/Veegee" ] && [ -f "$G/r6/tweaks/StreetNinja20_Collection.yaml" ] && [[ "$OUT" == *"Urban Techwear Outfit, Veegee Shop 3 will be removed: no longer part of the set"* ]]' "$OUT"
run update --yes
expect "and the run after it changes nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_RT" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_RT") <(snapshot "$G"))"
newworld eqexonly native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
cp "$FIX/round3/Equipment-EX "* "$FIX/round3/EquipmentEx-HideHubButtons-"* "$D/"
run install --yes --with-equipment-ex
expect "--with-equipment-ex alone brings the frameworks it needs, and nothing of the mod set" '[ $RC = 0 ] && [ -f "$G/r6/scripts/EquipmentEx/EquipmentEx.reds" ] && [ -f "$G/red4ext/Plugins/ArchiveXL/ArchiveXL.dll" ] && [ -f "$G/red4ext/Plugins/TweakXL/TweakXL.dll" ] && [ -f "$G/red4ext/Plugins/Codeware/Codeware.dll" ] && [ -f "$G/engine/tools/scc_lib.dll" ] && [ ! -e "$G/bin/x64/plugins/cyber_engine_tweaks.asi" ]' "$OUT"

# ------------------------------------------------- Cyber Engine Tweaks ----
section "Cyber Engine Tweaks installed alongside"
newworld cet native cet; OSR="$T/os-arch"
run install --yes
expect "version.dll override added too" '[ $RC = 0 ] && [ "$(hp reg-get "$PFX/user.reg" "$REG_KEY" version)" = native,builtin ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm,version=n,b\\\" gamemoderun %command% --launcher-skip" ]' "$OUT"

# ------------------------------------------------ newer RED4ext installed ----
section "A newer RED4ext is already installed"
newworld newer native; OSR="$T/os-arch"
cp "$FIX/pe/r4next/RED4ext.dll" "$G/red4ext/RED4ext.dll"; mkdir -p "$G/bin/x64"; cp "$FIX/pe/r4next/winmm.dll" "$G/bin/x64/winmm.dll"
run install --yes
expect "installed 1.32 is kept, not downgraded" '[ $RC = 0 ] && [ "$(hp pever "$G/red4ext/RED4ext.dll" product)" = 1.32.0 ] && [[ "$OUT" == *"keeping the installed RED4ext 1.32.0"* ]]' "$OUT"

# ------------------------------------------------- backup from the 1.x script ----
section "Backup made by the earlier Bazzite script"
newworld legacy native; OSR="$T/os-arch"
mkdir -p "$H/nightcoop-backup-2026-10-27-000000/game/red4ext" "$H/nightcoop-backup-2026-10-27-000000/prefix-runtime"
echo before > "$H/nightcoop-backup-2026-10-27-000000/game/red4ext/marker.txt"
run restore --yes
expect "legacy backup restored"       '[ $RC = 0 ] && [ -f "$G/red4ext/marker.txt" ] && [ -e "$H/nightcoop-backup-2026-10-27-000000/RESTORED" ]' "$OUT"

# -------------------------------------------------------- launch wrappers ----
section "Launch wrappers: game-performance when it can run, MangoHud when asked"
newworld wrap native; OSR="$T/os-cachyos"; TOOLS="$T/tools-cachy"
set_lo "%command% -skipStartScreen"
run check
expect "check: game-performance and MangoHud are installed, neither in use yet" '[[ "$OUT" == *"game-performance:"*"installed; run"*"to start the game with it"* ]] && [[ "$OUT" == *"MangoHud:"*"installed;"*"--mangohud"* ]]' "$OUT"
run install --yes
expect "CachyOS: game-performance goes in right before %command%; MangoHud only when asked" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" game-performance %command% --launcher-skip -skipStartScreen" ] && [[ "$OUT" == *"game-performance found: the game will run in the performance power profile"* ]] && [[ "$OUT" == *"MangoHud is installed: --mangohud shows its overlay in the game"* ]]' "$OUT"
run install --yes --mangohud
expect "--mangohud adds MANGOHUD=1 after the DLL overrides" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" MANGOHUD=1 game-performance %command% --launcher-skip -skipStartScreen" ] && [[ "$OUT" == *"MANGOHUD=1 shows its overlay"* ]]' "$OUT"
run install --yes
expect "a later run keeps both and has nothing to do" '[ $RC = 0 ] && [[ "$(launch_opts)" == *"MANGOHUD=1 game-performance %command%"* ]] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run check
expect "check: both in use" '[[ "$OUT" == *"game-performance:"*"in the launch options"* ]] && [[ "$OUT" == *"MangoHud:"*"in the launch options"* ]] && [[ "$OUT" != *"will not start"* ]]' "$OUT"
run install --yes --no-mangohud --no-game-performance
expect "--no-mangohud and --no-game-performance take both out" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip -skipStartScreen" ] && [[ "$OUT" == *"game-performance: taken out of the launch options"* ]] && [[ "$OUT" == *"MangoHud: taken out of the launch options"* ]]' "$OUT"
run install --yes
expect "--no-game-performance is remembered" '[ $RC = 0 ] && [[ "$(launch_opts)" != *game-performance* ]] && [[ "$OUT" == *"game-performance: left out of the launch options"* ]] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run install --yes --dry-run --game-performance
run install --yes
expect "a dry run does not change what is remembered" '[[ "$(launch_opts)" != *game-performance* ]]' "$(launch_opts)"
run install --yes --game-performance
expect "--game-performance puts it back" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" game-performance %command% --launcher-skip -skipStartScreen" ]' "$(launch_opts)"
set_lo "gamescope -W 1920 -H 1080 -- %command%"
run install --yes --mangohud
expect "in gamescope, --mangohud points to its --mangoapp, and game-performance goes inside it" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" gamescope -W 1920 -H 1080 -- game-performance %command% --launcher-skip" ] && [[ "$OUT" == *"MangoHud is not added: the launch options run the game in gamescope"*"--mangoapp"* ]]' "$OUT"

newworld wrapgp native; OSR="$T/os-cachyos"; TOOLS="$T/tools-gp"
set_lo "game-performance %command%"
run check
expect "check: game-performance without powerprofilesctl would stop the game" '[[ "$OUT" == *"game-performance:"*"in the launch options, but it needs powerprofilesctl (power-profiles-daemon), which is not installed"* ]] && [[ "$OUT" == *"the game will not start this way"* ]]' "$OUT"
run install --yes
expect "the install takes it out, saying why" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [[ "$OUT" == *"the launch options run game-performance, but it needs powerprofilesctl (power-profiles-daemon), which is not installed: the game would not start, so it is taken out"* ]]' "$OUT"
run install --yes --dry-run --no-game-performance
expect "a dry run with nothing to change remembers nothing either" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]] && [ ! -e "$H/.local/share/nightcoop-linux/settings.tsv" ]' "$OUT"
TOOLS="$T/tools-tlp-old"
run install --yes
expect "TLP's tlpctl is no help to a game-performance that knows only powerprofilesctl" '[ $RC = 0 ] && [[ "$(launch_opts)" != *game-performance* ]]' "$(launch_opts)"
TOOLS="$T/tools-gp-new"; set_lo "game-performance %command%"
run check
expect "a game-performance that knows tlpctl too names both" '[[ "$OUT" == *"game-performance:"*"in the launch options, but it needs powerprofilesctl (power-profiles-daemon) or tlpctl (TLP), and neither is installed"* ]]' "$OUT"
TOOLS="$T/tools-tlp"
run install --yes
expect "...and with tlpctl it can run, so it stays" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" game-performance %command% --launcher-skip" ]' "$(launch_opts)"

newworld wrapdeck native; OSR="$T/os-steamos"; TOOLS="$T/tools-deck"
set_lo "game-performance %command%"
run install --yes --mangohud
expect "SteamOS: game-performance (not on SteamOS) taken out; MangoHud not added, SteamOS has its own overlay" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [[ "$OUT" == *"the launch options run game-performance, but it is not installed"* ]] && [[ "$OUT" == *"MangoHud is not added: SteamOS has its own performance overlay (Quick Access menu > Performance)"* ]]' "$OUT"
run install --yes
expect "SteamOS: no MangoHud suggestion" '[ $RC = 0 ] && [[ "$OUT" != *"--mangohud shows"* ]] && [[ "$OUT" != *"MangoHud:"* ]]' "$OUT"

newworld wrapflat flatpak; OSR="$T/os-arch"; TOOLS="$T/tools-fp"
set_lo "game-performance %command%"
run install --yes --mangohud
expect "Flatpak Steam: the host's game-performance taken out; MangoHud's extension found, so MANGOHUD=1 goes in" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" MANGOHUD=1 %command% --launcher-skip" ] && [[ "$OUT" == *"the launch options run game-performance, but Flatpak Steam cannot run it"* ]]' "$OUT"
newworld wrapflat2 flatpak; OSR="$T/os-arch"; TOOLS="$T/tools-fp-nomh"
run install --yes --mangohud
expect "with the extension only for an older runtime, --mangohud names the one to install" '[ $RC = 0 ] && [[ "$(launch_opts)" != *MANGOHUD* ]] && [[ "$OUT" == *"MangoHud is not added: its Flatpak extension is not installed (flatpak install flathub org.freedesktop.Platform.VulkanLayer.MangoHud//26.08)"* ]]' "$OUT"

newworld wraparch native; OSR="$T/os-arch"
run install --yes --mangohud
expect "Arch without MangoHud: --mangohud says how to install it; other wrappers stay" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" gamemoderun %command% --launcher-skip" ] && [[ "$OUT" == *"MangoHud is not added: it is not installed (sudo pacman -S mangohud)"* ]]' "$OUT"
set_lo "mangohud %command%"
run check
expect "check: the mangohud wrapper without MangoHud stops the game" '[[ "$OUT" == *"MangoHud:"*"in the launch options, but it is not installed (sudo pacman -S mangohud)"* ]] && [[ "$OUT" == *"install MangoHud, or run"*"--no-mangohud"* ]]' "$OUT"
run install --yes --no-mangohud
expect "--no-mangohud takes the wrapper out" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ]' "$(launch_opts)"

# ----------------------------------------------------------- refusals ----
section "Refusals"
newworld nopfx native; rm -rf "$LIB/steamapps/compatdata"; OSR="$T/os-steamos"
run install --yes
expect "missing prefix explained (SteamOS wording)" '[ $RC != 0 ] && [[ "$OUT" == *"Launch Cyberpunk 2077 once"* ]]' "$OUT"
H="$T/empty"; mkdir -p "$H"
run check
expect "no Steam found"               '[ $RC != 0 ] && [[ "$OUT" == *"no Steam installation found"* ]]' "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAILED"
[ "$FAILED" = 0 ]
