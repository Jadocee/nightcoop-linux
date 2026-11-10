#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# End-to-end tests for nightcoop-install.sh against a synthetic Steam installation.
# Needs only bash, python3 and coreutils; no Steam, Wine or network access.
#
#   tests/run-tests.sh            run everything (most of an hour)
#   tests/run-tests.sh --quick    only the helpers' tests, in seconds, without the installs (the package's check())
#   KEEP=1 tests/run-tests.sh     keep the temporary folder for inspection

# Assertions are single-quoted strings evaluated by expect(), so variables used only
# inside them look unused to shellcheck.
# shellcheck disable=SC2016,SC2034

set -uo pipefail
QUICK=0
case "${1:-}" in --quick) QUICK=1 ;; "") ;; *) echo "usage: $0 [--quick]" >&2; exit 2 ;; esac
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
    -e "s#^VCREDIST_URLS=.*#VCREDIST_URLS=(\"file://$FIX/site/vc_redist.x64.exe\")#" \
    -e "s#^NEXUS_API=.*#NEXUS_API=\"file://$FIX/nexusapi\"#" "$SCRIPT" |
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

H="" OSR="$T/os-steamos" OUT="" TOOLS="$T/tools-none" RUNENV=()
run() {   # run <args...> : output in $OUT, status in $RC (RUNENV: more variables for it, NAME=value each)
    OUT="$(env -i PATH="$PATH" HOME="$H" LANG=C.UTF-8 DISPLAY=:0 NIGHTCOOP_ALLOW_ROOT=1 \
           NIGHTCOOP_OS_RELEASE="$OSR" NIGHTCOOP_TOOL_PATH="$TOOLS" ${RUNENV[@]+"${RUNENV[@]}"} bash "$NI" "$@" 2>&1)"; RC=$?
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
section "Launch options: the script writes the whole line"
lo() { hp lo-merge "$1" "${3:-winmm}" "${4:-}" "${5:-}" | cut -d$'\x1f' -f"$2"; }   # lo <line> <field> [dlls] [args] [wrappers]
expect "empty"                       '[ "$(lo "" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" ]'
expect "with the game arguments it adds" '[ "$(lo "" 2 winmm --launcher-skip)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command% --launcher-skip" ]'
expect "everything else is replaced: other overrides, variables, wrappers and arguments" '[ "$(lo "WINEDLLOVERRIDES=\"dxgi=n,b\" DXVK_HUD=fps gamemoderun %command% -skipStartScreen" 2 winmm --launcher-skip)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command% --launcher-skip" ]'
expect "Cyber Engine Tweaks loader joins" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" 2 winmm,version)" = "WINEDLLOVERRIDES=\"winmm,version=n,b\" %command%" ]'
expect "MANGOHUD=1 after the overrides, game-performance right before %command%" '[ "$(lo "prime-run %command%" 2 winmm --launcher-skip +game-performance,+mangohud)" = "WINEDLLOVERRIDES=\"winmm=n,b\" MANGOHUD=1 game-performance %command% --launcher-skip" ]'
expect "unwished, they are left out (the mangohud wrapper and its --dlsym too)" '[ "$(lo "MANGOHUD=1 mangohud --dlsym game-performance %command%" 2 winmm "" -game-performance,-mangohud)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" ]'
expect "the line the script writes is ok" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" game-performance %command% --launcher-skip" 1 winmm --launcher-skip +game-performance)" = ok ]'
expect "anything more is not" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" gamemoderun %command% --launcher-skip" 1 winmm --launcher-skip)" = missing ]'
expect "nor anything less" '[ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" 1 winmm --launcher-skip)" = missing ]'
expect "an override after %command% is broken" '[ "$(lo "%command% WINEDLLOVERRIDES=winmm=n,b" 1)" = broken ]'
expect "REDmod: -modded after the other game arguments, and the line with it is ok" '[ "$(lo "gamemoderun %command%" 2 winmm "--launcher-skip -modded")" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command% --launcher-skip -modded" ] && [ "$(lo "WINEDLLOVERRIDES=\"winmm=n,b\" %command% --launcher-skip -modded" 1 winmm "--launcher-skip -modded")" = ok ]'
expect "what a line runs: wrappers before %command%, not game arguments or variables" '[ "$(hp lo-uses "MANGOHUD=1 TOOL=/opt/x/game-performance gamescope -- %command% game-performance")" = "MANGOHUD=1 gamescope" ]'
expect "a quoted value is one word" '[ "$(hp lo-uses "DXVK_HUD=\"fps,  game-performance\" mangohud --dlsym %command%")" = mangohud ]'

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

if [ "$QUICK" = 1 ]; then   # --quick: the helpers alone; the installs into stand-in Steam folders take most of an hour
    printf '\n%d passed, %d failed (--quick: the installs are left out)\n' "$PASS" "$FAILED"
    [ "$FAILED" = 0 ]; exit
fi

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
expect "another user's plugin is cleared, into the backup" '[ ! -e "$G/red4ext/Plugins/OtherMod/other.dll" ] && [ -f "$(newest_backup)game/red4ext/Plugins/OtherMod/other.dll" ]'
expect "bundled RED4ext 1.31 used, nothing downloaded" '[ "$(hp pever "$G/red4ext/RED4ext.dll" product)" = 1.31.0 ] && [[ "$OUT" == *"using RED4ext 1.31.0 from the NightCoop archive"* ]] && [[ "$OUT" != *"downloading red4ext"* ]]' "$OUT"
expect "old build's leftover removed, as NightCoop's guide says" '[ ! -e "$G/red4ext/Plugins/NightCoop/old-helper.dll" ]'
expect "servers.txt and logs kept"    '[ -f "$G/red4ext/Plugins/NightCoop/servers.txt" ] && [ -f "$G/red4ext/Plugins/NightCoop/logs/nightcoop-last-crash.log" ]'
expect "runtime upgraded to 14.51"    '[ "$(hp pever "$PFX/drive_c/windows/system32/msvcp140.dll")" = 14.51.36247.0 ]'
expect "installer run with runinprefix" 'grep -q "^runinprefix .*vc_redist.x64.exe /install /quiet /norestart" "$PFX/../fake-proton.log"'
expect "newest installer chosen over Steamworks 14.44" '[[ "$OUT" == *"installer: $H/.cache/nightcoop-linux/vc_redist.x64.exe (14.51.36247.0)"* ]]' "$OUT"
expect "registry override written"    '[ "$(hp reg-get "$PFX/user.reg" "$REG_KEY" winmm)" = native,builtin ]'
expect "launch options written whole, the earlier line kept in the backup" '[ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [ "$(cat "$H"/.local/share/nightcoop-linux/backups/*/launch-options.txt)" = "gamemoderun %command% --launcher-skip" ] && [[ "$OUT" == *"the launch options are replaced as a whole; the earlier ones are kept in"* ]]' "$(launch_opts)"
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
expect "launch options recommended"   '[[ "$OUT" == *"Recommended (the prefix override already lets the mod load)"*"WINEDLLOVERRIDES=\"winmm=n,b\" %command% --launcher-skip"* ]]' "$OUT"
expect "Proton choice explained"      '[[ "$OUT" == *"Properties > Compatibility"*"choose Proton Experimental"* ]]' "$OUT"
expect "no 'manual step' demanded"    '[[ "$OUT" != *"One manual step left"* ]]' "$OUT"
run install --yes
kill "$STEAM_PID" 2>/dev/null; wait "$STEAM_PID" 2>/dev/null
expect "rerun with Steam still open only repeats the recommendations" '[ $RC = 0 ] && [[ "$OUT" == *"nothing to replace"* ]] && [[ "$OUT" == *"Recommended (the prefix override already lets the mod load)"* ]] && [[ "$OUT" != *"Backing up"* ]]' "$OUT"
run install --yes
expect "rerun with Steam closed writes only Steam's settings" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [ "$(tool)" = proton_experimental ] && [[ "$OUT" != *"Backing up"* ]]' "$OUT"

section "Steam open: closed and reopened to write its settings, but not in Game Mode"
# the script reopens Steam detached (setsid), so where the first process reaps nothing (a CI container's) a
# closed stand-in stays listed as a zombie: it counts as gone, here and in the script
steam_up() { local p s; for p in $(pgrep -u "$(id -u)" -x steam); do s=""; read -r _ _ s _ 2>/dev/null < "/proc/$p/stat" || continue; [ "$s" != Z ] && return 0; done; return 1; }
newworld reopen native; OSR="$T/os-arch"
mkdir -p "$T/steambin"   # a steam command that closes the stand-in Steam on -shutdown and starts it otherwise
printf '#!/bin/sh\nif [ "$1" = -shutdown ]; then pkill -u "$(id -u)" -x steam; exit 0; fi\nexec "%s/bin/steam"\n' "$T" > "$T/steambin/steam"; chmod +x "$T/steambin/steam"
mkdir -p "$T/bin"; [ -x "$T/bin/steam" ] || { printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$T/bin/steam"; chmod +x "$T/bin/steam"; }
"$T/bin/steam" & disown
for _ in 1 2 3 4 5 6 7 8 9 10; do steam_up && break; sleep 0.2; done
RUNENV=(XDG_CURRENT_DESKTOP=gamescope); PATH="$T/steambin:$PATH" run install --yes; RUNENV=()
expect "in Game Mode Steam stays open, and its settings wait, said so" '[ $RC = 0 ] && steam_up && [[ "$OUT" == *"Steam is running in Game Mode, so it will not be written now"* ]] && [[ "$(launch_opts)" != *"winmm=n,b"* ]]' "$OUT"
PATH="$T/steambin:$PATH" run update --yes --no-close-steam
expect "--no-close-steam leaves Steam open too" '[ $RC = 0 ] && steam_up && [[ "$OUT" == *"(--no-close-steam; the steps are shown at the end)"* ]] && [[ "$(launch_opts)" != *"winmm=n,b"* ]]' "$OUT"
PATH="$T/steambin:$PATH" run update --yes
for _ in 1 2 3 4 5 6 7 8 9 10; do steam_up && break; sleep 0.2; done
expect "by default Steam is closed, its settings written, and Steam reopened" '[ $RC = 0 ] && [[ "$OUT" == *"Closing Steam to write its settings"* ]] && [[ "$OUT" == *"reopening Steam"* ]] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [ "$(tool)" = proton_experimental ] && steam_up' "$OUT"
PATH="$T/steambin:$PATH" run update --yes
expect "and a rerun has nothing to do, so Steam is left alone" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]] && [[ "$OUT" != *"Closing Steam"* ]]' "$OUT"
pkill -u "$(id -u)" -x steam 2>/dev/null || true

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
expect "an interrupted backup is passed over" '[ $RC = 0 ] && [[ "$OUT" != *"2099-01-01-000000"* ]] && [ -f "$G/red4ext/RED4ext.dll" ]' "$OUT"
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
expect "and stay on the next run too, still this script's: clearing other mods leaves them" '[ $RC = 0 ] && [ -f "$P/ArchiveXL/ArchiveXL.dll" ] && [ -f "$P/input_loader/input_loader.dll" ] && [ -f "$G/engine/tools/scc_lib.dll" ] && [[ "$OUT" != *"mods this script did not install"* ]]' "$OUT"
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
section "Mods this script did not install: cleared on install, into the backup (--keep-other-mods leaves them)"
newworld others native; OSR="$T/os-arch"
others() {   # mods installed by hand, in each place of mods, and the game's own DLL beside their loaders
    mkdir -p "$G/archive/pc/mod" "$G/r6/scripts/Other" "$G/r6/tweaks/Other" "$G/red4ext/Plugins/OtherPlugin" "$G/mods/OtherRedmod" \
             "$G/bin/x64/plugins/cyber_engine_tweaks/mods/OtherCet" "$G/red4ext/logs"
    printf 'RDAR' > "$G/archive/pc/mod/other.archive"; printf '// other\n' > "$G/r6/scripts/Other/other.reds"
    printf 'x: 1\n' > "$G/r6/tweaks/Other/other.yaml"; printf 'MZ other' > "$G/red4ext/Plugins/OtherPlugin/other.dll"
    printf '{"name": "other"}\n' > "$G/mods/OtherRedmod/info.json"; printf -- '-- other\n' > "$G/bin/x64/plugins/cyber_engine_tweaks/mods/OtherCet/init.lua"
    printf 'MZ asi' > "$G/bin/x64/other.asi"; printf 'MZ loader' > "$G/bin/x64/version.dll"; printf 'log\n' > "$G/red4ext/logs/red4ext.log"
}
others; GAME_DLLS="$(ls "$G/bin/x64")"; WITH_OTHERS="$(snapshot "$G")"
run install --yes --keep-other-mods
expect "--keep-other-mods leaves the mods installed by hand where they are" '[ $RC = 0 ] && [ -f "$G/r6/scripts/Other/other.reds" ] && [ -f "$G/archive/pc/mod/other.archive" ] && [ -f "$G/bin/x64/version.dll" ] && [[ "$OUT" != *"mods this script did not install"* ]]' "$OUT"
run uninstall --yes
run install --yes
expect "by default an install clears every mod it did not install, in every place of mods, and says so" '[ $RC = 0 ] && [ ! -e "$G/archive/pc/mod/other.archive" ] && [ ! -e "$G/r6/scripts/Other/other.reds" ] && [ ! -e "$G/r6/tweaks/Other/other.yaml" ] && [ ! -e "$G/red4ext/Plugins/OtherPlugin/other.dll" ] && [ ! -e "$G/mods/OtherRedmod/info.json" ] && [ ! -e "$G/bin/x64/plugins/cyber_engine_tweaks/mods/OtherCet/init.lua" ] && [ ! -e "$G/bin/x64/other.asi" ] && [ ! -e "$G/bin/x64/version.dll" ] && [[ "$OUT" == *"file(s) of mods this script did not install, into the backup"* ]]' "$OUT"
expect "NightCoop, RED4ext, its log and the game's own DLLs stay" '[ -f "$G/red4ext/Plugins/NightCoop/NightCoop.dll" ] && [ -f "$G/red4ext/RED4ext.dll" ] && [ -f "$G/bin/x64/winmm.dll" ] && [ -f "$G/red4ext/logs/red4ext.log" ] && [ -f "$G/bin/x64/Cyberpunk2077.exe" ]' "$(ls -R "$G/red4ext" "$G/bin/x64")"
expect "what was cleared is in the backup" '[ -f "$(newest_backup)game/r6/scripts/Other/other.reds" ] && [ -f "$(newest_backup)game/bin/x64/version.dll" ]' "$(newest_backup)"
run update --yes
expect "the next run has nothing to clear" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run uninstall --yes
expect "uninstall brings the mods installed by hand back, exactly" '[ $RC = 0 ] && [ "$WITH_OTHERS" = "$(snapshot "$G")" ]' "$(diff <(echo "$WITH_OTHERS") <(snapshot "$G"))"
run install --yes --with-flight
mkdir -p "$G/red4ext/Plugins/let_there_be_flight"; printf '{"mine": 1}\n' > "$G/red4ext/Plugins/let_there_be_flight/settings.json"
run update --yes
expect "the script's own mods keep what they write while playing" '[ $RC = 0 ] && grep -q mine "$G/red4ext/Plugins/let_there_be_flight/settings.json" && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"

section "A GitHub download that fails (GitHub answers 504 for redscript's releases at times)"
newworld ghdown native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
RS="redscript-v0.5.32-windows.zip"
sed "s#file://$FIX/gh/$RS#file://$FIX/gh-unreachable/$RS#" "$NI" > "$T/ni-ghdown.sh"   # its download fails, as GitHub's 504 does
NI_NOW="$NI"; NI="$T/ni-ghdown.sh"
run install --yes --with-flight
expect "the run goes on: NightCoop installs, redscript is listed to download in a browser, and what needs it waits" '[ $RC = 0 ] && [ -f "$G/red4ext/Plugins/NightCoop/NightCoop.dll" ] && [ ! -e "$G/engine/tools/scc_lib.dll" ] && [ ! -e "$G/red4ext/Plugins/let_there_be_flight" ] && [[ "$OUT" == *"could not be downloaded (see above): download each in a browser into $H/Downloads"*"redscript: file://$FIX/gh-unreachable/$RS"* ]] && [[ "$OUT" == *"Let There Be Flight needs redscript, which is not here"* ]]' "$OUT"
printf 'not redscript' > "$D/$RS"
run update --yes
expect "a file of that name with another SHA-256 is not taken" '[ $RC = 0 ] && [ ! -e "$G/engine/tools/scc_lib.dll" ] && [[ "$OUT" == *"redscript: file://$FIX/gh-unreachable/$RS"* ]]' "$OUT"
cp "$FIX/gh/$RS" "$D/$RS"
run update --yes
expect "the copy downloaded in a browser is taken from the Downloads folder (its SHA-256 matching), and what needs it follows" '[ $RC = 0 ] && grep -q "redscript lib 0.5.32" "$G/engine/tools/scc_lib.dll" && [ -f "$G/red4ext/Plugins/let_there_be_flight/let_there_be_flight.dll" ] && [[ "$OUT" != *"could not be downloaded"* ]] && [ -f "$H/.cache/nightcoop-linux/mods/$RS" ]' "$OUT"
rm "$D/$RS"
run update --yes
expect "later runs use the script's own copy, and an installed redscript stays when its download fails" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
rm "$H/.cache/nightcoop-linux/mods/$RS"; run update --yes
expect "with no copy at all, the installed redscript stays, said so" '[ $RC = 0 ] && grep -q "redscript lib 0.5.32" "$G/engine/tools/scc_lib.dll" && [[ "$OUT" == *"keeping the installed redscript: its download failed"* ]]' "$OUT"
NI="$NI_NOW"

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
expect "the mod set brings Let There Be Flight and Input Loader, so the run does not suggest --with-flight" '[ "$(fver "$P/let_there_be_flight/let_there_be_flight.dll")" = 0.3.20 ] && [ "$(fver "$P/input_loader/input_loader.dll")" = 0.2.6 ] && [[ "$OUT" != *"Add --with-flight"* ]]' "$OUT"
expect "Cyber Drift: the Light file, over a newer full one and the one for 2.3" '[ -f "$CETM/CyberDrift Light/init.lua" ] && [ ! -e "$CETM/CyberDrift" ] && [ ! -e "$G/r6/tweaks/CyberDrift" ] && [[ "$OUT" != *"does not look like the light file"* ]]' "$OUT"
expect "what is not downloaded yet is listed with its Nexus page" '[[ "$OUT" == *"A.G.I.S. (the main file, PUBLICNET): https://www.nexusmods.com/cyberpunk2077/mods/10909?tab=files"* ]] && [[ "$OUT" == *"Night City Marketplace: https://www.nexusmods.com/cyberpunk2077/mods/4433?tab=files"* ]] && [[ "$OUT" == *"Quick Stash: https://www.nexusmods.com/cyberpunk2077/mods/30016?tab=files"* ]] && [[ "$OUT" == *"Native Settings UI: https://www.nexusmods.com/cyberpunk2077/mods/3518?tab=files"* ]] && [[ "$OUT" == *"Virtual Car Dealer: https://www.nexusmods.com/cyberpunk2077/mods/4454?tab=files"* ]] && [[ "$OUT" == *"Drive an Aerial Vehicle: https://www.nexusmods.com/cyberpunk2077/mods/13842?tab=files"* ]]' "$OUT"
run check
expect "check lists the mods and what is missing" '[[ "$OUT" == *"Mods:"*"Let There Be Flight 0.3.20, Virtual Atelier 1.6.4, No Intro Videos 0.5, Cyber Drift 2.31, with redscript 0.5.32, ArchiveXL 1.28.6, TweakXL 1.12.0, Input Loader 0.2.6, Codeware 1.21.2, Cyber Engine Tweaks 1.38.1, Mod Settings 0.2.28, Audioware 1.11.1 (kept up to date by this script)"* ]] && [[ "$OUT" == *"Let There Be Flight:"*"0.3.20, with the mod set (kept up to date by this script)"* ]] && [[ "$OUT" == *"missing: Native Settings UI, A.G.I.S., Night City Marketplace, Virtual Car Dealer, Quick Stash, Drive an Aerial Vehicle"* ]]' "$OUT"
find "$D" -maxdepth 1 -type f -delete   # the Downloads folder cleaned up: the installer kept its own copies
cp "$NX/PUBLICNET-10909-1-2-1-1702220953.zip" "$NX/BLACKWALL-10909-1-2-1-1702221109.zip" "$NX/Darks Night City Marketplace-4433-2-3-0-1757877636.zip" \
   "$NX/Quick Stash-30016-v1-1-1779816414.zip" "$NX/Virtual Car Dealer 4454 2.3.0 2026-10-25T11-18Z lcXrcZZMt.zip" \
   "$NX/Native Settings UI 1.97 3518 1.97 2026-10-22T15-26Z cB3xB00Va.zip" "$NX/Drive an Aerial Vehicle 13842 3.5.0 2026-10-26T16-09Z mPgaPVV1e.zip" "$D/"
run update --yes
expect "the rest install once downloaded: A.G.I.S.'s main file, out of its folder, without its read-me" '[ $RC = 0 ] && [ -f "$G/r6/scripts/AGIS/agis.reds" ] && [ ! -e "$G/r6/scripts/AGIS_BLACKWALL" ] && [ ! -e "$G/readme.txt" ] && [ ! -e "$G/AGIS" ] && [ -f "$G/r6/scripts/NCMarketplace/stores.reds" ] && [ -f "$CETM/QuickStash/init.lua" ] && [ -f "$G/r6/scripts/VirtualCarDealer/core/CarDealer-System.reds" ] && [ -f "$CETM/nativeSettings/init.lua" ] && [ -f "$DAV/init.lua" ] && [ -f "$P/DriveAerialVehicle/DriveAerialVehicle.dll" ]' "$OUT"
expect "the mods downloaded first stay, from the installer's own copies" '[ -f "$G/r6/scripts/virtual-atelier-full/Config.reds" ] && [ -f "$CETM/CyberDrift Light/init.lua" ] && [[ "$OUT" != *"cyberpunk2077/mods/2987?tab=files"* ]]' "$OUT"
expect "co-op notes: Quick Stash, and cars and AVs of mods" '[[ "$OUT" == *"NightCoop keeps a guest'"'"'s stash their own"* ]] && [[ "$OUT" == *"otherwise NightCoop shows a game car with as many seats"* ]]' "$OUT"
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
run update --yes --without-flight
expect "--without-flight with the mod set on: Let There Be Flight stays, and the run says why" '[ $RC = 0 ] && [ -f "$P/let_there_be_flight/let_there_be_flight.dll" ] && [[ "$OUT" == *"Let There Be Flight stays: the mod set includes it"* ]] && [[ "$OUT" != *"nothing to remove"* ]]' "$OUT"
run update --yes --with-flight
expect "both sets: Let There Be Flight and the shared frameworks once" '[ $RC = 0 ] && [ -f "$P/let_there_be_flight/let_there_be_flight.dll" ] && [[ "$OUT" == *"Add-ons: flight, mods"* ]]' "$OUT"
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
newworld style native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"   # Iconic Shops needs Phantom Liberty
P="$G/red4ext/Plugins"; VC="$G/bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCustomizerSVE"; PRISTINE_STYLE="$(snapshot "$G")"
ZCORE="$FIX/round5/Zenitex Core Dependency 16356 5.1.8 2026-08-21T11-39Z JSKWSQkA8.zip"   # every Zenitex outfit needs it
cp "$FIX/nexus/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$FIX/nexus/Virtual Car Dealer 4454 2.3.0 2026-10-25T11-18Z lcXrcZZMt.zip" "$FIX"/style/* "$ZCORE" "$D/"
run install --yes --with-mods
expect "the clothing stores, and the Zenitex outfits by their main files only (no Alt. Colors, GS or Gymfiend file)" '[ $RC = 0 ] && [ -f "$G/r6/scripts/AllVanillaClothes/store.reds" ] && [ -f "$G/r6/scripts/iconicshop/shops/top.reds" ] && [ -f "$G/r6/scripts/ScorpionTank/scorpion_zenitex_virtual_atelier.reds" ] && ( for i in mask harness jacket pads pants gloves; do [ -f "$G/r6/tweaks/scorpiontank/zenitex_$i.yaml" ] && [ ! -e "$G/r6/tweaks/scorpiontank/zenitex_${i}_gs.yaml" ] || exit 1; done ) && [ ! -e "$G/r6/tweaks/scorpiontank/zenitex_mask_alt.yaml" ] && [ -f "$G/r6/tweaks/scorpiontank/comfy_boots.yaml" ] && [ ! -e "$G/r6/tweaks/scorpiontank/comfy_boots_gymfiend.yaml" ] && [ ! -e "$G/codes.txt" ]' "$OUT"
expect "both car packs of one Nexus mod, the bikes' main file only, the Supra and the Porsche with what they need" '[ -f "$G/r6/tweaks/VirtualCarDealer/car_pack_1.yaml" ] && [ -f "$G/r6/tweaks/VirtualCarDealer/car_pack_2.yaml" ] && [ -f "$G/r6/tweaks/Methodd/Methodd_Edge/mthdd_Methodd_Edge.yaml" ] && [ -f "$G/archive/pc/mod/BDF_DRe_ArchV4.archive" ] && [ ! -e "$G/archive/pc/mod/BDF_DRe_ArchV4_Mirrors.archive" ] && [ ! -e "$G/archive/pc/mod/dre_cyberhelmets.archive" ] && [ -f "$G/r6/tweaks/VehicleExitFix/exit.yaml" ] && [ -f "$G/r6/tweaks/krnlnik/supra.yaml" ] && [ ! -e "$G/r6/tweaks/krnlnik/supra_colors.yaml" ] && [ -f "$G/r6/scripts/VMF/vmf.reds" ] && [ -f "$G/archive/pc/mod/porsche_gt3rs.archive" ] && [ ! -e "$G/archive/pc/mod/porsche_gt3rs_grey_red.archive" ] && [ -f "$G/archive/pc/mod/MaterialTextureOverride.archive" ] && [ ! -e "$G/mods/MaterialTextureOverride" ]' "$OUT"
expect "Vehicle Customizer: its 3.1 update on top of 3.0" '[ "$(cat "$VC/init.lua")" = "-- vehicle customizer 3.1" ] && [ -f "$VC/data/appearances.json" ]' "$OUT"
expect "co-op notes: outfits of mods, and Vehicle Customizer's language" '[[ "$OUT" == *"a partner without the same outfit mod sees a plain game piece"* ]] && [[ "$OUT" == *"Vehicle Customizer works only with the game'"'"'s language set to English"* ]]' "$OUT"
expect "co-op note: a guest's vehicles of the mods that define them in .tweak files are not in their garage in the host's world" '[[ "$OUT" == *"Bikes of the Dark Future and Toyota Supra HKS in co-op: a guest"* ]] && [[ "$OUT" == *"these mods use .tweak files"* ]]' "$OUT"
printf '{"Quadra": "b"}\n' > "$VC/saved.json"   # customisations saved while playing, one in a file no archive ships
printf '{"Quadra": "Mizutani"}\n' > "$VC/replacements.json"
run update --yes
expect "Vehicle Customizer's saved customisations stay, in a file it ships and one it writes itself, in a folder two components share; a rerun changes nothing" '[ $RC = 0 ] && grep -q Quadra "$VC/saved.json" && grep -q Mizutani "$VC/replacements.json" && [ "$(cat "$VC/init.lua")" = "-- vehicle customizer 3.1" ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run update --yes --without-mods
expect "--without-mods removes the clothing and vehicles, Let There Be Flight too; Material and Texture Override, Zenitex Core Dependency and Input Loader stay as frameworks" '[ $RC = 0 ] && [ ! -e "$P/let_there_be_flight" ] && [ -f "$P/input_loader/input_loader.dll" ] && [ ! -e "$G/r6/scripts/iconicshop" ] && [ ! -e "$G/r6/tweaks/scorpiontank/zenitex_mask.yaml" ] && [ -f "$G/r6/tweaks/scorpiontank/#_scorpion_zenitex_core_dependency.yaml" ] && [ ! -e "$G/r6/tweaks/VirtualCarDealer" ] && [ ! -e "$G/archive/pc/mod/porsche_gt3rs.archive" ] && [ ! -e "$VC" ] && [ -f "$G/archive/pc/mod/MaterialTextureOverride.archive" ]' "$OUT"
run uninstall --yes
expect "uninstall leaves the file Vehicle Customizer saved while playing, which no install put there, and names the folder it stays in" '[ $RC = 0 ] && grep -q Mizutani "$VC/replacements.json" && [[ "$OUT" == *"left in place because they now hold other files"*"bin/x64/plugins"* ]]' "$OUT"
rm -f -- "$VC/replacements.json"; rmdir -- "$VC" "$G/bin/x64/plugins/cyber_engine_tweaks/mods" "$G/bin/x64/plugins/cyber_engine_tweaks" "$G/bin/x64/plugins" 2>/dev/null
expect "uninstall puts the rest of the game folder back exactly" '[ "$PRISTINE_STYLE" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_STYLE") <(snapshot "$G"))"
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
expect "check: Equipment-EX is kept up to date, with its frameworks" '[[ "$OUT" == *"Equipment-EX:"*"Equipment EX 1.2.10, with redscript 0.5.32, ArchiveXL 1.28.6, TweakXL 1.12.0, Codeware 1.21.2 (kept up to date by this script)"* ]]' "$OUT"
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
cp "$FIX/round3/Equipment-EX "* "$FIX/round3/EquipmentEx-HideHubButtons-"* "$FIX/round4/V's Bullet Necklace"* "$FIX/round4/Accessories - Main Store"* "$D/"
run install --yes --with-equipment-ex
expect "--with-equipment-ex alone brings the frameworks it needs, and nothing of the mod set" '[ $RC = 0 ] && [ -f "$G/r6/scripts/EquipmentEx/EquipmentEx.reds" ] && [ -f "$G/red4ext/Plugins/ArchiveXL/ArchiveXL.dll" ] && [ -f "$G/red4ext/Plugins/TweakXL/TweakXL.dll" ] && [ -f "$G/red4ext/Plugins/Codeware/Codeware.dll" ] && [ -f "$G/engine/tools/scc_lib.dll" ] && [ ! -e "$G/bin/x64/plugins/cyber_engine_tweaks.asi" ]' "$OUT"
expect "raem's jewellery waits for the mod set too, and is not missing without it" '[ ! -e "$G/r6/tweaks/raem" ] && [ ! -e "$G/r6/scripts/raem" ] && [[ "$OUT" != *"Bullet Necklace"* ]]' "$OUT"
run check
expect "check: the Equipment-EX row without the jewellery, and no jewellery missing" '[[ "$OUT" == *"Equipment-EX:"*"Equipment EX 1.2.10, with redscript 0.5.32, ArchiveXL 1.28.6, TweakXL 1.12.0, Codeware 1.21.2 (kept up to date"* ]] && [[ "$OUT" != *"Bullet Necklace"* ]] && [[ "$OUT" != *"Palette"* ]] && [[ "$OUT" != *"raem"* ]]' "$OUT"

# ------------------------------- the fourth round: Zenitex gear, hair and jewellery ----
section "Mods (--with-mods): Zenitex gear, hairstyles and Nola Dreamer's boutique; raem's jewellery only with Equipment-EX too"
newworld round4 native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"   # a game with Phantom Liberty
PRISTINE_R4="$(snapshot "$G")"
R4_DL=("$FIX/nexus/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$FIX/style/Zenitex Virtual Atelier 10090 4.13 2026-08-28T15-44Z gMz5MuNQO.zip"
       "$FIX/round3/ND_Mini_dress_with_glasses_FemV-15704-1-1-1747683086.zip" "$FIX/round3/Equipment-EX 6945 1.2.10 2026-10-25T21-07Z k8Iw8mmPd.zip" "$FIX"/round4/*
       "$FIX/round5/Zenitex Core Dependency 16356 5.1.8 2026-08-21T11-39Z JSKWSQkA8.zip" "$FIX/round5/The Community Palette Project-10437-1-1-1710101546.zip")
cp "${R4_DL[@]}" "$D/"
# later releases of the files two rules pass over: Preem Hair's 4K file, and one of Hyst's single hairs
cp "$FIX/round4/Preem Hair (4K) 8223 3.0.0 2026-10-21T01-20Z G5yE5CC3f.zip" "$D/Preem Hair (4K) 8223 3.0.1 2026-11-20T09-00Z G5yE5CC3g.zip"
cp "$FIX/round4/Kim Hair-21766-1-0-1762627938.zip" "$D/Kim Hair 21766 1.3 2026-11-20T09-00Z Co8doe62f.zip"
run install --yes --with-mods
expect "the seven Zenitex outfits, its goggles and balaclavas (with Phantom Liberty, the three that need it too), not their GS or Alt. Colors files" '[ $RC = 0 ] && ( for f in military_combat_armor military_opscore_helmet military_armored_ballistic_vest military_combat_boots military_dual_pistol_holsters military_zenitex_backpack military_zenitex_underwear military_accessories_zenitex_goggles zenitex_balaclava_pack; do [ -f "$G/r6/tweaks/scorpiontank/scorpion_$f.yaml" ] || exit 1; done ) && ! ls "$G/archive/pc/mod" | grep -q -i _addon_ && [[ "$OUT" != *"Phantom Liberty is not installed"* ]]' "$OUT"
expect "hair: Preem Hair's 2K file (a newer 4K file too), the five Wolfcut files for the character creator (not the old replacers), Subleader's and Hyst's all-in-one files, the Megapak out of its folder, the four undercuts" 'came "archive/pc/mod/###-PreemHair.archive" "(2K)" && ( for f in NUT_wolfcut_messy_ccxl NUT_wolfcut_emo_ccxl NUT_hime_short NUT_hime_medium NUT_hime_jelly_ccxl HALK_Hair_SlickBackUndercut HALK_CCXL_Hair_SideWaveUndercut HALK_CCXL_Hair_ManBunUndercut HALK_CCXL_Hair_SlickBackBraidsUndercut; do [ -f "$G/archive/pc/mod/$f.xl" ] || exit 1; done ) && ! ls "$G/archive/pc/mod" | grep -q wolfemo && came archive/pc/mod/CCXL_Sub_HairPack_Wolf.xl AllInOne && came archive/pc/mod/hyst_kim_hair_ccxl.xl "ALL IN ONE" && [ -f "$G/archive/pc/mod/MELUMINARY - CCXL - CAROLINE INVERTED BOB.xl" ] && [ ! -e "$G/CCXL - MEGAPAK" ] && [ ! -e "$G/CCXL - WINONA" ]' "$OUT"
expect "Nola Dreamer's boutique (its file for Fem V), which sells the mini dress, so no note on it; no jewellery without Equipment-EX; the co-op note on hair" '[ -f "$G/r6/scripts/ND_female_virtual_boutique.reds" ] && [ ! -e "$G/r6/scripts/ND_male_virtual_boutique.reds" ] && [[ "$OUT" != *"No store of the set sells"* ]] && [ ! -e "$G/r6/tweaks/raem" ] && [ ! -e "$G/r6/scripts/raem" ] && [[ "$OUT" == *"Hairstyles of mods in co-op"* ]] && [[ "$OUT" == *"sees your V without that hairstyle"* ]]' "$OUT"
run update --yes
expect "a rerun changes nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run update --yes --with-equipment-ex
expect "--with-equipment-ex brings raem's jewellery and the store that sells it, not raem's other stores" '[ $RC = 0 ] && [ -f "$G/r6/scripts/EquipmentEx/EquipmentEx.reds" ] && [ -f "$G/r6/tweaks/raem/rm_acc_neck_bulletv.yaml" ] && [ -f "$G/r6/tweaks/raem/rm_acc_set_doll.yaml" ] && [ -f "$G/archive/pc/mod/rm_acc_rings_reyes.xl" ] && [ -f "$G/r6/scripts/raem/rm_atelier_accessories_main.reds" ] && [ ! -e "$G/r6/scripts/raem/rm_atelier_clothes_main.reds" ] && [ ! -e "$G/r6/scripts/raem/rm_atelier_accessories_pearls.reds" ] && [ ! -e "$G/archive/pc/mod/rm_00_acc_set_doll_MESH_masc_neck 6 higher fit.archive" ]' "$OUT"
run check
expect "check: the jewellery in the Equipment-EX row, the hair in the mod set's" '[[ "$OUT" == *"Equipment-EX:"*"Bullet Necklace 1.1"*"(kept up to date by this script)"* ]] && [[ "$OUT" == *"Mods:"*"Preem Hair 3.0.0"*"Undercut Slickback Braids 1.1"* ]]' "$OUT"
run update --yes --without-equipment-ex
expect "--without-equipment-ex takes the jewellery out with it; the hair and the Zenitex gear stay" '[ $RC = 0 ] && [ ! -e "$G/r6/tweaks/raem" ] && [ ! -e "$G/r6/scripts/raem" ] && [ -f "$G/archive/pc/mod/NUT_hime_short.xl" ] && [ -f "$G/r6/tweaks/scorpiontank/scorpion_zenitex_balaclava_pack.yaml" ]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_R4" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_R4") <(snapshot "$G"))"
newworld round4nopl native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"   # a game without Phantom Liberty
cp "${R4_DL[@]}" "$D/"
run install --yes --with-mods
expect "without Phantom Liberty, the helmet, holsters and backpack that need it are left out, and said so; the rest is installed" '[ $RC = 0 ] && [ ! -e "$G/r6/tweaks/scorpiontank/scorpion_military_opscore_helmet.yaml" ] && [ ! -e "$G/r6/tweaks/scorpiontank/scorpion_military_dual_pistol_holsters.yaml" ] && [ ! -e "$G/r6/tweaks/scorpiontank/scorpion_military_zenitex_backpack.yaml" ] && [ -f "$G/r6/tweaks/scorpiontank/scorpion_military_combat_boots.yaml" ] && [[ "$OUT" == *"Phantom Liberty is not installed: Iconic Shops, Zenitex FAST Helmet, Zenitex Pistol Holsters, Zenitex Military Backpack, "*"which need it, are left out"* ]]' "$OUT"
run check
expect "check does not count them as missing" '[ $RC = 0 ] && [[ "$OUT" != *"FAST Helmet"* ]] && [[ "$OUT" != *"Pistol Holsters"* ]]' "$OUT"

# ------------------------ the fifth round: what the mods need, and four more mods ----
section "Mods (--with-mods): Zenitex Core Dependency and The Community Palette Project; Immersive First Person, Katana Pack 2, Browser Extension, Curbside"
R5_DL=("$FIX/nexus/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$FIX/style/IconicShops 7215 3.6.2 2026-11-04T06-43Z FKtYKrCFm.zip"
       "$FIX/round4/Zenitex Balaclava Pack-17411-2-1-1780145222.zip" "$FIX/round3/Equipment-EX 6945 1.2.10 2026-10-25T21-07Z k8Iw8mmPd.zip"
       "$FIX/round4/Chain Jewelry - Main-15861-1-2-1728769757.zip" "$FIX/round4/Reyes Accessories - Main File-17069-1-1-1741904576.zip")
newworld round5 native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"
PRISTINE_R5="$(snapshot "$G")"
cp "${R5_DL[@]}" "$FIX"/round5/* "$D/"
# newer files that the rules pass over: a colour set of Zenitex Core, one blade of Katana Pack 2, Browser Extension's example
cp "$FIX/round5/Zenitex Core Dependency - Verdant Set-16356-4-1-3-1766449434.zip" "$D/Zenitex Core Dependency - Verdant Set 16356 5.2 2026-11-20T09-00Z Co8doe62g.zip"
cp "$FIX/round5/Nagakiba 36164 1.1 2026-11-07T04-36Z JSKWSQsh2.zip" "$D/Nagakiba 36164 1.2 2026-11-20T09-00Z Co8doe62h.zip"
cp "$FIX/round5/BrowserExtensionExample-10038-0-9-1697377093.zip" "$D/BrowserExtensionExample 10038 0.9.8 2026-11-20T09-00Z Co8doe62i.zip"
run install --yes --with-mods --with-equipment-ex
expect "Zenitex Core Dependency by its main file (not a newer colour set), so the balaclavas install" '[ $RC = 0 ] && [ -f "$G/r6/tweaks/scorpiontank/#_scorpion_zenitex_core_dependency.yaml" ] && [ -f "$G/archive/pc/mod/#_scorpion_zenitex_core_dependency.xl" ] && ! ls "$G/archive/pc/mod" | grep -q -i verdant && [ -f "$G/r6/tweaks/scorpiontank/scorpion_zenitex_balaclava_pack.yaml" ]' "$OUT"
expect "The Community Palette Project, a bare .archive, goes into archive/pc/mod; Chain Jewelry and Reyes Accessories follow" '[ -f "$G/archive/pc/mod/TheCommunityPaletteProject_MLTemplateResource.archive" ] && [ ! -e "$G/TheCommunityPaletteProject_MLTemplateResource.archive" ] && [ ! -e "$G/.bare-files" ] && [ -f "$G/r6/tweaks/raem/rm_acc_set_doll.yaml" ] && [ -f "$G/archive/pc/mod/rm_acc_rings_reyes.xl" ]' "$OUT"
expect "Immersive First Person (CET mod, plugin, scripts), not its file for Immersive Third Person, which it passes over quietly" '[ -f "$G/bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/init.lua" ] && [ -f "$G/red4ext/Plugins/ImmersiveFirstPerson/ImmersiveFirstPerson.dll" ] && [ -f "$G/r6/scripts/ImmersiveFirstPerson/LookAt.reds" ] && [ ! -e "$G/archive/pc/mod/0_ImmersiveFirstPerson_ITP_Compat.archive" ] && [[ "$OUT" != *"ITP Compatibility"* ]]' "$OUT"
expect "Katana Pack 2 by its file with every blade (not a newer single blade), Browser Extension's framework (not its newer example), Curbside" '[ -f "$G/archive/pc/mod/Katana_Pack_2.archive" ] && [ -f "$G/r6/scripts/KatanaPack2_Scripts/KatanaCyberfang.reds" ] && [ -f "$G/r6/audioware/KatanaPack2Sounds/SwordOfNight.yml" ] && [ ! -e "$G/archive/pc/mod/Katana_Nagakiba.archive" ] && [ -f "$G/r6/scripts/BrowserExtension/BrowserExtension.System.reds" ] && [ ! -e "$G/r6/scripts/CustomSiteExample" ] && [ ! -e "$G/archive/pc/mod/CustomSiteExample.archive" ] && [ -f "$G/r6/scripts/Curbside/CBS_Run.reds" ]' "$OUT"
expect "Iconic Shops with Phantom Liberty there; the co-op note on Katana Pack 2" '[ -f "$G/r6/scripts/iconicshop/shops/top.reds" ] && [[ "$OUT" != *"Phantom Liberty is not installed"* ]] && [[ "$OUT" == *"Katana Pack 2 in co-op: a partner without it sees a game blade of the same kind in your hands"* ]]' "$OUT"
run update --yes
expect "a rerun changes nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run check
expect "check: Zenitex Core Dependency and the four mods in the mod set's row, The Community Palette Project in Equipment-EX's" '[[ "$OUT" == *"Mods:"*"Immersive First Person 2.2.0, Katana Pack 2 1.1, Curbside 1.0.1"*"Zenitex Core Dependency 5.1.8"*"Browser Extension 0.9.7"* ]] && [[ "$OUT" == *"Equipment-EX:"*"The Community Palette Project 1.1"* ]]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_R5" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_R5") <(snapshot "$G"))"
newworld round5needs native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"   # no Phantom Liberty, no Zenitex Core, no palette
cp "${R5_DL[@]}" "$D/"
cp "$FIX/round5/Zenitex Core Dependency - Verdant Set-16356-4-1-3-1766449434.zip" "$D/Zenitex Core Dependency - Verdant Set 16356 5.2 2026-11-20T09-00Z Co8doe62g.zip"
run install --yes --with-mods --with-equipment-ex
expect "without Zenitex Core Dependency the balaclavas are left out; its colour set is not taken for it, and its page is named" '[ $RC = 0 ] && [ ! -e "$G/r6/tweaks/scorpiontank/scorpion_zenitex_balaclava_pack.yaml" ] && ! ls "$G/archive/pc/mod" | grep -q -i verdant && [[ "$OUT" == *"Zenitex Balaclava Pack needs Zenitex Core Dependency, which is not here"* ]] && [[ "$OUT" == *"Verdant Set 16356 5.2 2026-11-20T09-00Z Co8doe62g.zip is not installed: it is another file of Zenitex Core Dependency than the one this script takes (the main file, not No Camo, Black Decals or a colour set)"* ]] && [[ "$OUT" == *"Zenitex Core Dependency (the main file, not No Camo, Black Decals or a colour set): https://www.nexusmods.com/cyberpunk2077/mods/16356?tab=files"* ]]' "$OUT"
expect "without The Community Palette Project, Chain Jewelry and Reyes Accessories are left out" '[ ! -e "$G/r6/tweaks/raem/rm_acc_set_doll.yaml" ] && [ ! -e "$G/archive/pc/mod/rm_acc_rings_reyes.xl" ] && [[ "$OUT" == *"Reyes Accessories needs The Community Palette Project, which is not here"* ]] && [[ "$OUT" == *"The Community Palette Project: https://www.nexusmods.com/cyberpunk2077/mods/10437?tab=files"* ]]' "$OUT"
expect "without Phantom Liberty, Iconic Shops is left out, and said so" '[ ! -e "$G/r6/scripts/iconicshop" ] && [[ "$OUT" == *"Phantom Liberty is not installed: Iconic Shops, "* ]]' "$OUT"
mkdir -p "$T/bare-two/One" "$T/bare-two/Two"; printf 'RDAR one' > "$T/bare-two/One/palette.archive"; printf 'RDAR two' > "$T/bare-two/Two/palette.archive"
(cd "$T/bare-two" && python3 -I -m zipfile -c "$D/The Community Palette Project 10437 1.2 2026-11-20T09-00Z Co8doe62j.zip" One Two)
run update --yes
expect "a download of bare .archive files in two folders (versions to choose from) is not installed" '[ $RC = 0 ] && [[ "$OUT" == *"Co8doe62j.zip has no game folders (r6, archive, bin, red4ext) or .archive files in it"* ]] && [ ! -e "$G/archive/pc/mod/palette.archive" ] && [[ "$OUT" == *"The Community Palette Project is left out: none of its downloads can be used"* ]]' "$OUT"

section "Mods (--with-mods): round 7: the clubs and the Afterlife opened, Here's Brendan, traffic, cars, menus, clothes and eyes"
R7_DL=("$FIX/nexus/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip" "$FIX/nexus/Virtual Car Dealer 4454 2.3.0 2026-10-25T11-18Z lcXrcZZMt.zip"
       "$FIX/nexus/Native Settings UI 1.97 3518 1.97 2026-10-22T15-26Z cB3xB00Va.zip" "$FIX/style/VMF-28744-1-0-1775609654.zip")
newworld round7 native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"
PRISTINE_R7="$(snapshot "$G")"; AM="$G/archive/pc/mod"; CETM="$G/bin/x64/plugins/cyber_engine_tweaks/mods"
cp "${R7_DL[@]}" "$FIX/round3/Deceptious Quest Core "* "$FIX"/round7/* "$D/"
run install --yes --with-mods
expect "the clubs and the Afterlife by their files for 2.5 (not the 2.31 builds, Remastered, No Bouncers or Doors), and Here's Brendan" '[ $RC = 0 ] && [ -f "$AM/The_Empathy_Club_Unlocked.xl" ] && [ ! -e "$AM/The_Empathy_Club_Remastered.xl" ] && [ ! -e "$AM/The_Empathy_Club_No_Bouncers_2.5.xl" ] && [ ! -e "$AM/The_Empathy_Club_Unlocked_1.1.xl" ] && [ -f "$AM/Dicky_Twister_Club_Unlocked.xl" ] && [ ! -e "$AM/Dicky_Twister_Club_Unlocked_1.0.xl" ] && [ -f "$AM/Heavy_Hearts_Club_Unlocked.xl" ] && [ ! -e "$AM/Heavy_Hearts_Club_Unlocked_1.0.xl" ] && [ -f "$AM/Afterlife_Unlocked_&_Remastered.xl" ] && [ ! -e "$AM/Afterlife_Unlocked_&_Remastered_Doors_1.1.xl" ] && [ -f "$G/r6/tweaks/HeresBrendan/heresbrendan.yaml" ]' "$OUT"
expect "Night City Traffic Overhaul v2.51 (not v3.04), Bike Overhaul (not its ArchV4 patch), the three cars, the Polestar without its spoiler patch" '[ -f "$G/r6/scripts/NightCityTrafficOverhaul/NCTO.reds" ] && [ ! -e "$G/r6/scripts/NightCityTrafficOverhaul/NCTOexternal.reds" ] && [ -f "$G/r6/tweaks/BikeOverhaul/apollo.yaml" ] && [ ! -e "$G/r6/tweaks/ArchV4_Fyrn.tweak" ] && [ -f "$AM/oranje3_edgerunner_emperor.xl" ] && [ -f "$G/r6/scripts/cornmilf_cars/supra_a70_pop_up.reds" ] && [ -f "$AM/aabdii_polestar_1_hero.xl" ] && [ ! -e "$AM/!_polestar_1_no_spoiler_patch.archive" ]' "$OUT"
expect "the menus and loot icons: Loot Icons Extension's Light file (no DLL), Fluff Vendor Fixes' main file, Unified Mod Settings" '[ -f "$G/r6/scripts/clear_skill_checks.reds" ] && [ -f "$G/r6/scripts/filter_saves.reds" ] && [ -f "$AM/LootIconsExtensionLight.archive" ] && [ ! -e "$AM/LootIconsExtension.archive" ] && [ ! -e "$G/red4ext/Plugins/loot_icons_extension_fix" ] && grep -q "6ZNKZczf8" "$G/r6/scripts/FluffVendorFixes/FluffVendorFixes.reds" && [ -f "$CETM/UnifiedModSettings/init.lua" ]' "$OUT"
expect "FPP Speedometer without its toggle (Let There Be Flight takes O), the clothes, the shoes with their store, the eyes (not the no-highlights file)" '[ -f "$G/r6/scripts/FPPSpeedometer/FPPSpeedometer.reds" ] && [ ! -e "$G/r6/input/fpp_speedometer.xml" ] && [ -f "$AM/Dusty_MaxTacSuit.archive" ] && [ -f "$AM/prestigeglasses.archive" ] && [ -f "$AM/DrCatherwood_Nike_AirJordan_Euro.archive" ] && [ -f "$G/r6/scripts/drcatherwood/drcatherwoodatelier-atelier-store.reds" ] && [ -f "$AM/BeautifulExoticsCCXL.archive" ] && [ ! -e "$AM/BeautifulExoticsNoHighlightsCCXL.archive" ]' "$OUT"
expect "the co-op notes: places, eyes, traffic, vendors, the speedometer, the console codes and the MaxTac layers" '[[ "$OUT" == *"a partner without them sees locked doors and walls where you walk"* ]] && [[ "$OUT" == *"sees your V with one of the game'"'"'s eye colours"* ]] && [[ "$OUT" == *"the host'"'"'s traffic is everyone'"'"'s"* ]] && [[ "$OUT" == *"Fluff Vendor Fixes changes the street vendors'"'"' records"* ]] && [[ "$OUT" == *"its toggle key is left out"* ]] && [[ "$OUT" == *"No store of the set sells MaxTac Suit or Prestige Glasses"* ]] && [[ "$OUT" == *"MaxTac Suit'"'"'s pieces are worn together with Equipment-EX"* ]]' "$OUT"
run update --yes
expect "a rerun changes nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_R7" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_R7") <(snapshot "$G"))"
newworld round7nopl native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"   # no Phantom Liberty
cp "${R7_DL[@]}" "$FIX"/round7/* "$D/"
run install --yes --with-mods
expect "without Phantom Liberty the clubs, the Afterlife, the traffic overhaul and the MaxTac Suit wait, said so" '[ $RC = 0 ] && [ ! -e "$G/archive/pc/mod/The_Empathy_Club_Unlocked.xl" ] && [ ! -e "$G/r6/scripts/NightCityTrafficOverhaul" ] && [ ! -e "$G/archive/pc/mod/Dusty_MaxTacSuit.archive" ] && [[ "$OUT" == *"Phantom Liberty is not installed:"*"The Empathy Club Unlocked"*"Night City Traffic Overhaul"*"MaxTac Suit"* ]] && [ -f "$G/archive/pc/mod/prestigeglasses.archive" ]' "$OUT"

section "Settings the script writes for co-op, on every install (the player's other settings stay)"
newworld cfg native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"
MS="$G/red4ext/Plugins/mod_settings/user.ini" CB="$G/bin/x64/plugins/cyber_engine_tweaks/bindings.json"
DAVS="$G/bin/x64/plugins/cyber_engine_tweaks/mods/DriveAerialVehicle/Data/user_setting_v3.json"
mkdir -p "$(dirname "$MS")" "$(dirname "$CB")"
printf '[Other.Mod]\nmine = 7\n\n[NightCityTrafficOverhaul.Settings.NCTOSettings]\ntrafficHijackDifficulty = HARD\n' > "$MS"   # the player's settings
printf '{"cet": {"overlay_key": 0}, "SomeMod": {"go": 12666373951979520}}\n' > "$CB"
PRISTINE_CFG="$(snapshot "$G")"
cp "$FIX/nexus/Native Settings UI 1.97 3518 1.97 2026-10-22T15-26Z cB3xB00Va.zip" "$FIX/nexus/Drive an Aerial Vehicle 13842 3.5.0 2026-10-26T16-09Z mPgaPVV1e.zip" \
   "$FIX/round3/Immersive Voice Distance (2.5) 36809 1.2.0 2026-11-07T13-09Z NEnvE30eR.zip" "$FIX/round7/Loot Icons Extension Light 16386 1.60 2026-10-27T06-36Z D2ZS2nnCn.zip" \
   "$FIX/round7/NightCityTrafficOverhaul v2.51 (2.31 and 2.5) 25552 2.51 2026-10-27T00-16Z IieOigg7C.zip" "$D/"
ini() { awk -v s="[$2]" -v k="$3" '$0 == s { on = 1; next } /^\[/ { on = 0 } on && $1 == k { print $3 }' "$1"; }   # ini <file> <section> <key>
run install --yes --with-mods
expect "Mod Settings' file gets the co-op values: loot icons kept while aiming and scanning, story lines carrying further, traffic's safe defaults pinned (HARD put back to VANILLA)" '[ $RC = 0 ] && [ "$(ini "$MS" LootIconsExtension.LootIconsExtensionSSX fMS_ADSOpacity)" = 100.0 ] && [ "$(ini "$MS" LootIconsExtension.LootIconsExtensionSSX fMS_ScannerOpacity)" = 100.0 ] && [ "$(ini "$MS" ImmersiveAudioDistance.IAD_Settings quest)" = 200.0 ] && [ "$(ini "$MS" NightCityTrafficOverhaul.Settings.NCTOSettings trafficHijackDifficulty)" = VANILLA ] && [ "$(ini "$MS" NightCityTrafficOverhaul.Settings.NCTOSettings autoDistributeModdedVehicles)" = false ] && [ "$(grep -c -i "^trafficHijackDifficulty" "$MS")" = 1 ] && [ "$(ini "$MS" Other.Mod mine)" = 7 ] && [[ "$OUT" == *"settings for co-op:"* ]]' "$(cat "$MS"; echo; echo "$OUT" | grep -i setting)"
expect "Cyber Engine Tweaks gets an overlay key that clashes with nothing, the player's other bindings kept; Drive an Aerial Vehicle's 5 moves to 9" '[ "$(python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[\"cet\"][\"overlay_key\"], d[\"SomeMod\"][\"go\"])" "$CB")" = "54043195528445952 12666373951979520" ] && [ "$(python3 -I -c "import json,sys; print([e[\"key\"] for e in json.load(open(sys.argv[1]))[\"common_keybind_table\"] if e[\"name\"] == \"toggle_appearance\"][0])" "$DAVS")" = IK_9 ]' "$(cat "$CB" "$DAVS")"
run update --yes
expect "a rerun has nothing to do" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
sed -i 's/^trafficHijackDifficulty = VANILLA/trafficHijackDifficulty = EASY/' "$MS"   # the player changes them in game
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["cet"]["overlay_key"] = 12666373951979520; json.dump(d, open(sys.argv[1], "w"))' "$CB"
run update --yes
expect "the next run puts the co-op values back, but keeps an overlay key the player chose" '[ $RC = 0 ] && [ "$(ini "$MS" NightCityTrafficOverhaul.Settings.NCTOSettings trafficHijackDifficulty)" = VANILLA ] && [ "$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))[\"cet\"][\"overlay_key\"])" "$CB")" = 12666373951979520 ]' "$(cat "$MS" "$CB")"
run uninstall --yes
expect "uninstall puts the player's own files back exactly" '[ $RC = 0 ] && [ "$PRISTINE_CFG" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_CFG") <(snapshot "$G"))"

section "Mods (--with-mods): round 9: hair, makeup and eyes, menus, combat, crowds, places and a car"
R9_DL=("${R7_DL[@]}" "$FIX/round3/Deceptious Quest Core 7831 3.3.3 2026-10-27T04-49Z E91D9ddiK.zip"
       "$FIX/round3/Immersive Voice Distance (2.5) 36809 1.2.0 2026-11-07T13-09Z NEnvE30eR.zip" "$FIX/style/Material and Texture Override-5266-1-2-1695907754.zip")
js() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(json.dumps(d.get(k)) for k in sys.argv[2:]))' "$@"; }   # js <file> <key>...
newworld round9 native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"
PRISTINE_R9="$(snapshot "$G")"; AM="$G/archive/pc/mod"; CETM="$G/bin/x64/plugins/cyber_engine_tweaks/mods"; R6S="$G/r6/scripts"
MS="$G/red4ext/Plugins/mod_settings/user.ini" SSJ="$CETM/SilentSilencersAndKnives/settings.json" SAJ="$CETM/sitAnywhere/config/config.json"
cp "${R9_DL[@]}" "$FIX"/round9/* "$D/"
run install --yes --with-mods
expect "the seven hairs, Updo's all-in-one file (its bare files into archive/pc/mod, not the single Chevelle), the Mecha eyes" '[ $RC = 0 ] && [ -f "$AM/Atomiic_Violet_Hair_CCXL.archive" ] && grep -q G5yE5CJPT "$AM/RVLL_CCXL_Chevelle_Updo.xl" && [ -f "$AM/RVLL_CCXL_Bel_Air_Updo.archive" ] && [ ! -e "$G/RVLL_CCXL_Bel_Air_Updo.archive" ] && [ -f "$AM/ZXR - CCXL Hair - Himiko Buns.xl" ] && [ -f "$AM/atomiic_yumeko_hair_ccxl.xl" ] && [ -f "$AM/MELUMINARY - CCXL - XYLA SHAG MULLET.xl" ] && [ -f "$AM/_0_Vesna_HoV_HAIR_MV_Geralt_CCXL.archive.xl" ] && [ -f "$AM/atomiic_softbluntbob_ccxl.xl" ] && [ -f "$G/r6/tweaks/protoss/protoss_MechaRoboticEyesCCXL.yaml" ] && [ -f "$G/r6/tweaks/protoss/protoss_MechaRoboticEyesPart2CCXL.yaml" ]' "$OUT"
expect "the makeup by the files for the basegame head: Beautiful Makeup by its pinned upload (not the newer file of the same name), Makeup II (not EKT), the 256x256 enhancer" 'grep -q 1777732105 "$AM/Arkhe_Beautiful_Makeup_Base_CCXL.xl" && grep -q "Basegame Head" "$AM/Arkhe_Beautiful_Makeup_02_Base_CCXL.xl" && grep -q 256x256 "$AM/!_Arkhe_MAKEUP_Enhancer.archive"' "$OUT"
expect "the menus: the loading-screen fix (not No Load Popups), Always First Equip (not its translation sources), the attribute reset, Mark To Sell, Purify The UI (not its vanilla-aberration file)" '[ -f "$R6S/Modded Save Loading Screen Fix/Modded Save Loading Screen Fix.reds" ] && [ ! -e "$R6S/Modded Save Loading Screen Fix/Modded Save Loading Screen Fix - No Load Popups.reds" ] && grep -q mPgaPVVHG "$R6S/alwaysFirstEquip.reds" && [ -f "$R6S/ResetAttributesAlwaysAvailable.reds" ] && [ -f "$G/r6/input/MarkToSell.xml" ] && [ -f "$AM/_Disable ONLY 2D Effect For UI And Disable Chrom Ab.archive" ] && [ ! -e "$AM/_Disable ONLY 2D Effect For UI And Keep Vanilla Chrom Ab.archive" ]' "$OUT"
expect "Always First Equip moved off F2 and F3 (NightCoop's F-key quickhacks) to F11 and Insert, in Mod Settings' file and its input file" '[ "$(ini "$MS" AlwaysFirstEquip.FirstEquipConfig afeMainHotkey) $(ini "$MS" AlwaysFirstEquip.FirstEquipConfig afeAdditionalHotkey)" = "IK_F11 IK_Insert" ] && grep -q "<button id=\"IK_F11\" overridableUI=\"afeMainHotkey\"" "$G/r6/input/AlwaysFirstEquip.xml" && grep -q "<button id=\"IK_Insert\" overridableUI=\"afeAdditionalHotkey\"" "$G/r6/input/AlwaysFirstEquip.xml" && ! grep -q -e IK_F2 -e IK_F3 "$G/r6/input/AlwaysFirstEquip.xml"' "$(cat "$MS" "$G/r6/input/AlwaysFirstEquip.xml")"
expect "combat: Apex Grapple (not its file for 2.31) with pulling people off in its five profiles, the stealth and dual-wield fixes, Stealth Finishers, the crowd patch by its redscript file" 'grep -q LACBAIvh4 "$R6S/ApexGrapple/Hook.reds" && [ "$(for p in Settings Profile2 Profile3 Profile4 Profile5; do ini "$MS" "ApexGrapple$p" pullPeople; done | sort -u)" = false ] && [ -f "$R6S/StealthFixes/StealthFixesCrouch.reds" ] && [ -f "$G/r6/tweaks/DualWieldingFix.yaml" ] && [ -f "$R6S/ZKVTakedowns2/ZKV_StealthFinishers.reds" ] && [ -f "$CETM/ZKVTakedowns2/init.lua" ] && [ -f "$R6S/No Crowd panic from devices/no_crowd_panic_from_devices.reds" ] && [ ! -e "$CETM/No Crowd panic from devices" ]' "$(cat "$MS")"
expect "Silent Silencers: its settings file written with the same values for everyone, its cover debuff off" '[ -f "$CETM/SilentSilencersAndKnives/init.lua" ] && [ "$(js "$SSJ" afterStealthHitNoKillDebuff afterStealthHitKillDebuff shouldSilencedGunshotsBeStealthy silencedGunshotMinDistance baseDetectionChance secondsToDetect)" = "false false true 2.0 0 0" ]' "$(cat "$SSJ")"
expect "crowds, places and a car: Crowd Voice Unlocked, the ripperdocs and bars, Sit Anywhere with its HUD kept (its other settings as shipped), the vehicle reactions, the parking spots (not the alt file), the 240SX 1.32" '[ -f "$AM/CrowdVoiceUnlocked.archive" ] && [ -f "$R6S/ImmersiveRippers/ImmersiveRippers.reds" ] && [ -f "$AM/ImmersiveBartenders.archive" ] && [ "$(js "$SAJ" hideUI sitAnimation hideExitPopup)" = "false 1 false" ] && [ -f "$G/r6/tweaks/NPCVehicleReactionsFixed/NPCVehicleReactionsFixed.yaml" ] && [ -f "$AM/#MotelParkingFix.archive" ] && [ -f "$AM/ParkingSpotsEnhanced.archive" ] && [ ! -e "$AM/ParkingSpotsEnhancedAlt.archive" ] && grep -q 1702907275 "$G/r6/tweaks/nissan_240sx.yaml"' "$(cat "$SAJ")"
expect "the co-op notes: makeup, Himiko's bangs without Equipment-EX, the moved keys, the reset, places and scenes, parking, NPCs, Silent Silencers, Apex Grapple, Sit Anywhere, crowd voices, the console codes" '[[ "$OUT" == *"Eye makeup of mods in co-op: choose it in the character creator"* ]] && [[ "$OUT" == *"bangs are items for the face slot without Equipment-EX"* ]] && [[ "$OUT" == *"Always First Equip: its keys are F11"* ]] && [[ "$OUT" == *"Reset Attributes always available: a reset changes only your own character"* ]] && [[ "$OUT" == *"Places, scenes and quests of mods in co-op"* ]] && [[ "$OUT" == *"Immersive Rippers and Immersive Bartenders in co-op: a visit is your own"* ]] && [[ "$OUT" == *"Parking Spots Enhanced starts once V has been in the H10 apartment"* ]] && [[ "$OUT" == *"Mods that change how NPCs act (Stealth Fixes, Silent Silencers, Stealth Finishers, No Crowd Panic From Devices and Fixed NPC Vehicle Reactions)"* ]] && [[ "$OUT" == *"Silent Silencers in co-op: its settings are written the same for everyone"* ]] && [[ "$OUT" == *"Apex Grapple in co-op: partners see your V fly"* ]] && [[ "$OUT" == *"Sit Anywhere in co-op: a partner sees you sit only with Sit Anywhere too"* ]] && [[ "$OUT" == *"Crowd Voice Unlocked in co-op: each game voices the people near its own V"* ]] && [[ "$OUT" == *"No store of the set sells Himiko Buns Hair: add them"* ]]' "$OUT"
run update --yes
expect "a rerun changes nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
sed -i 's/^pullPeople = false/pullPeople = true/' "$MS"   # the player changes them in game
printf '{"sitAnimation":3,"hideExitPopup":true,"hideUI":true}' > "$SAJ"
printf '{"debuffDuration": 9.0, "afterStealthHitNoKillDebuff": true, "baseDetectionChance": 50}' > "$SSJ"
run update --yes
expect "the next run puts the co-op values back and keeps the player's other choices (Sit Anywhere's own file is the player's)" '[ $RC = 0 ] && [ "$(ini "$MS" ApexGrappleProfile3 pullPeople)" = false ] && [ "$(js "$SAJ" hideUI sitAnimation hideExitPopup)" = "false 3 true" ] && [ "$(js "$SSJ" afterStealthHitNoKillDebuff baseDetectionChance debuffDuration)" = "false 0 9.0" ]' "$(cat "$MS" "$SAJ" "$SSJ")"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_R9" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_R9") <(snapshot "$G"))"
newworld round9needs native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"   # no Immersive Audio Distance, Deceptious Quest Core or Material and Texture Override
cp "${R7_DL[@]}" "$FIX"/round9/* "$D/"
run install --yes --with-mods
expect "a mod whose requirement is missing waits, and says which: crowd voices, the parking spots and the 240SX" '[ $RC = 0 ] && [ ! -e "$G/archive/pc/mod/CrowdVoiceUnlocked.archive" ] && [ ! -e "$G/archive/pc/mod/ParkingSpotsEnhanced.archive" ] && [ ! -e "$G/r6/tweaks/nissan_240sx.yaml" ] && [[ "$OUT" == *"Crowd Voice Unlocked needs Immersive Audio Distance, which is not here"* ]] && [[ "$OUT" == *"Parking Spots Enhanced needs Deceptious Quest Core, which is not here"* ]] && [[ "$OUT" == *"Nissan 240SX needs Material and Texture Override, which is not here"* ]] && [ -f "$G/archive/pc/mod/ImmersiveBartenders.archive" ]' "$OUT"

section "Mods (--with-mods): round 10: fixes, tooltips, the wanted HUD, scopes and apartment cats"
newworld round10 native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"
PRISTINE_R10="$(snapshot "$G")"; AM="$G/archive/pc/mod"; R6S="$G/r6/scripts"
cp "${R9_DL[@]}" "$FIX"/round10/* "$D/"
run install --yes --with-mods
expect "the fixes: fast travel, the aerial takedowns' Lethal files (not Non Lethal or Bare Hands Bloodless), the cutscene guns, Deceptious Bug Fixes" '[ $RC = 0 ] && [ -f "$R6S/AccidentalFastTravelBugFix.reds" ] && grep -q MTheTjhQw "$R6S/Mantis Blades Aerial Takedown Fix/Mantis Blades Aerial Takedown Fix.reds" && [ -f "$R6S/Gorilla Arms Aerial Takedown Fix/Gorilla Arms Aerial Takedown Fix.reds" ] && [ ! -e "$R6S/Bare Hand Aerial Takedown Bloodless" ] && [ -f "$R6S/CutsceneWeaponSwapper.reds" ] && [ -f "$AM/#DeceptiousBugFixes.archive.xl" ] && [ -f "$G/r6/tweaks/#DeceptiousBugFixes/DeceptiousBugFixes.yaml" ]' "$OUT"
expect "the tooltips, the wanted stars, and Preem Scopes by its main file with Smart Weapons and Binoculars (not with Frame, the FOMOD, compatibility or No Scope Crosshairs files)" '[ -f "$R6S/BetterArmorTooltip.reds" ] && [ -f "$AM/BetterArmorTooltip.archive.xl" ] && [ -f "$R6S/CyberwareScreenTooltipFix.reds" ] && [ -f "$R6S/dynamic_wanted_stars/DynamicWantedStars.reds" ] && grep -q 1744383914 "$AM/PreemScopes.archive" && [ -f "$AM/PreemScopes-Smart.archive" ] && grep -q 1701895039 "$AM/PreemScopes-Binoculars.archive" && [ ! -e "$AM/PreemScopes-MHCompat.archive" ] && [ ! -e "$AM/##PreemScopes-NoScopeCrosshairs.archive" ] && [ ! -e "$AM/#PreemScopes.archive" ]' "$OUT"
expect "the apartment cats: Corpo Plaza by its main file (not the Colour Variants of 2022), Japantown, the motel, the Glen, Dogtown, and Custom Cats' Base files (not the 4k replacer or the variants)" '[ -f "$AM/#CorpoCat.archive" ] && [ -f "$G/r6/tweaks/CorpoCat_Red.yaml" ] && [ ! -e "$G/CorpoCat_Blue.yaml" ] && ! find "$G" -name "CorpoCat_Blue.yaml" | grep -q . && [ -f "$AM/JapanCat.archive.xl" ] && [ -f "$AM/MotelCat.archive.xl" ] && [ -f "$AM/LoftCat.archive.xl" ] && [ -f "$G/r6/tweaks/DogtownCat.yaml" ] && grep -q 1740786536 "$AM/#ApartmentCatsCustoms_Base.archive" && grep -q 1740786536 "$AM/#ApartmentCatsCustoms_Motel_OrangeWhite.archive" && [ ! -e "$AM/#ApartmentCatsCustoms_Motel_GreyTiger.archive" ]' "$OUT"
expect "the co-op notes: aerial takedowns, cutscene guns, the places with Deceptious Bug Fixes and the cats, the cats, the wanted stars" '[[ "$OUT" == *"Aerial Takedowns Fix in co-op: an aerial takedown with Mantis Blades or Gorilla Arms kills"* ]] && [[ "$OUT" == *"Cutscene Weapon Swapper in co-op: each game puts its own V"* ]] && [[ "$OUT" == *"the parking spots, Deceptious Bug Fixes, the apartment cats, the Immersion Patch quest fixes, the"* ]] && [[ "$OUT" == *"Deceptious Bug Fixes in co-op: its quest fixes act in the host"* ]] && [[ "$OUT" == *"Apartment cats in co-op: the apartments and what V bought are the host"* ]] && [[ "$OUT" == *"try each apartment"* ]] && [[ "$OUT" == *"Dynamic Wanted Stars in co-op: your stars show your own wanted level"* ]]' "$OUT"
run update --yes
expect "a rerun changes nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_R10" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_R10") <(snapshot "$G"))"
newworld round10alone native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"   # Non Lethal only; no Deceptious Quest Core or Phantom Liberty
cp "${R7_DL[@]}" "$FIX/round10/Mantis Blades Aerial Takedown Fix - Non Lethal 34044 1.0.0 2026-09-18T04-08Z gMz5MuzG3.zip" "$FIX/round10/Deceptious Bug Fixes "* \
   "$FIX/round10/Apartment Cats - Dogtown 10325 2.0.0 2026-09-10T19-17Z lcXrcZX8T.zip" "$FIX/round10/Apartment Cats - The Glen "* "$D/"
run install --yes --with-mods
expect "the Non Lethal file alone is not taken for the Lethal fix, saying why; Deceptious Bug Fixes waits for Deceptious Quest Core" '[ $RC = 0 ] && [ ! -e "$G/r6/scripts/Mantis Blades Aerial Takedown Fix" ] && [[ "$OUT" == *"gMz5MuzG3.zip is not installed: it is Mantis Blades Aerial Takedown Fix - Non Lethal, which replaces the Lethal file"* ]] && [ ! -e "$G/archive/pc/mod/#DeceptiousBugFixes.archive" ] && [[ "$OUT" == *"Deceptious Bug Fixes needs Deceptious Quest Core, which is not here"* ]]' "$OUT"
expect "without Phantom Liberty the Dogtown cat waits, said so; the Glen's cat comes" '[ ! -e "$G/archive/pc/mod/DogtownCat.archive" ] && [[ "$OUT" == *"Phantom Liberty is not installed:"*"Apartment Cats Dogtown"* ]] && [ -f "$G/archive/pc/mod/LoftCat.archive.xl" ]' "$OUT"

section "Mods (--with-mods): round 11: gameplay and quest fixes"
newworld round11 native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"
PRISTINE_R11="$(snapshot "$G")"; AM="$G/archive/pc/mod"; R6S="$G/r6/scripts"; CETM="$G/bin/x64/plugins/cyber_engine_tweaks/mods"
cp "${R9_DL[@]}" "$FIX"/round11/* "$FIX/round9/Immersive Bartenders-7203-2-0-3-1752967023.zip" "$D/"
run install --yes --with-mods
expect "the gameplay fixes, Dash Fix and Easier Controller Sprint by their 2.5 releases (not 1.0.0 and 1.1.0)" '[ $RC = 0 ] && grep -q Q6xF6llzo "$R6S/DashFix/DashFix.reds" && [ -f "$AM/DashFix.archive.xl" ] && grep -q 5em9eooDJ "$R6S/EasierControllerSprint.reds" && [ -f "$R6S/HolsterStaminaBarBugFix.reds" ] && [ -f "$R6S/DodgesFix.reds" ] && [ -f "$R6S/Eye In The Sky Highlight Fix.reds" ] && [ -f "$R6S/Melee Finisher Camera Fix/MeleeFinisherCameraFix.reds" ]' "$OUT"
expect "the quest fixes with their CET parts, the Kerry scene, vehicle motion, the voiceline, the adverts and the air traffic fix" '[ -f "$AM/! anygoodname_cp77_story_quest_fixes.xl" ] && [ -f "$CETM/anygoodname_cp77_story_quest_fixes/init.lua" ] && [ -f "$AM/! minor_activities_quest_fixes.xl" ] && [ -f "$CETM/minor_activities_quest_fixes/init.lua" ] && [ -f "$AM/! holding_on_kerry_mansion_scene_fixes.archive" ] && [ -f "$AM/! quest_vehicle_motion_fixes.xl" ] && [ -f "$AM/Delete Few Weeks Tops.archive" ] && [ -f "$AM/!Fix_Advert_Animations.archive" ] && [ -f "$AM/AirTrafficDupeFix.archive" ]' "$OUT"
expect "the co-op notes: the dodging fix among the NPC mods, the quest fixes among the places and their own note, Pepe with Immersive Bartenders" '[[ "$OUT" == *"Mods that change how NPCs act (Enemies Dodging Fix)"* ]] && [[ "$OUT" == *"the Immersion Patch quest fixes, the"* ]] && [[ "$OUT" == *"or other scenes and vote choices"* ]] && [[ "$OUT" == *"Immersion Patch quest fixes in co-op: in a session they act in the host"* ]] && [[ "$OUT" == *"Pepe at El Coyote Cojo plays Story Quest Fixes"* ]]' "$OUT"
run update --yes
expect "a rerun changes nothing" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_R11" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_R11") <(snapshot "$G"))"
newworld round11old native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"   # only the releases before 2.5
cp "${R7_DL[@]}" "$FIX/round11/Easier Controller Sprint-26610-1-1-0-1767608356.zip" "$FIX/round11/Dash Fix-16272-1-0-0-1723844109.zip" "$D/"
run install --yes --with-mods
expect "Easier Controller Sprint 1.1.0 and Dash Fix 1.0.0 alone are not installed: patch 2.5 needs 1.1.1 and 1.0.1" '[ $RC = 0 ] && [ ! -e "$G/r6/scripts/EasierControllerSprint.reds" ] && [ ! -e "$G/r6/scripts/DashFix" ] && [[ "$OUT" == *"Easier Controller Sprint-26610-1-1-0-1767608356.zip is Easier Controller Sprint 1.1.0; game 2.5 needs 1.1.1 or newer"* ]] && [[ "$OUT" == *"Dash Fix-16272-1-0-0-1723844109.zip is Dash Fix 1.0.0; game 2.5 needs 1.0.1 or newer"* ]]' "$OUT"

# ------------------------------------------------------ Nexus Mods API ----
section "Nexus Mods API: with a Premium account's key, the script downloads the Nexus mods itself"
# the fake API (mkfixtures.py nexus_api) lists the fixtures' Nexus downloads, decoys and all, and links them
API="$FIX/nexusapi/v1/games/cyberpunk2077/mods" NKEY='Tst0KEY+abc/def==--ghiJKL012--mno345PQR=='
EQL="$API/6945/files/$(cat "$FIX/nexusapi/eqex-fid")"   # Equipment-EX's file, whose download the tests spoil
EQ10="Equipment-EX 6945 1.2.10 2026-10-25T21-07Z k8Iw8mmPd.zip" EQ11="Equipment-EX 6945 1.2.11 2026-11-06T10-00Z Lt7Qw2zXa.zip"
keyfile() {   # keyfile [mode] [key]: the key in the default key file
    mkdir -p "$H/.config/nightcoop-linux"; (umask 077; printf '%s\n' "${2:-$NKEY}" > "$H/.config/nightcoop-linux/nexus-api-key")
    chmod "${1:-600}" "$H/.config/nightcoop-linux/nexus-api-key"
}
fetched() { grep -c "^  downloading .* from Nexus Mods$" <<<"$OUT"; }   # how many files the run downloaded from Nexus Mods
NEXUS_N="$(awk 'NF == 8 && $8 ~ /^nexus:/' "$FIX/addon-sets.txt" | wc -l)" GITHUB_N="$(awk 'NF == 9' "$FIX/addon-sets.txt" | wc -l)"
NEXUS_IDS="$(awk 'NF == 8 && $8 ~ /^nexus:/ { split($8, a, ":"); print a[2] }' "$FIX/addon-sets.txt" | sort -u | wc -l)"
newworld napi native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D" "$G/archive/pc/ep1"
CETM="$G/bin/x64/plugins/cyber_engine_tweaks/mods"; C="$H/.cache/nightcoop-linux"; PRISTINE_NAPI="$(snapshot "$G")"
keyfile; BEFORE="$(snapshot "$H")"
run install --yes --dry-run --with-mods --with-equipment-ex
expect "a dry run lists what a real run would download from Nexus Mods, downloads none of it, and changes nothing, not even the cache" '[ $RC = 0 ] && [[ "$OUT" == *"A real run downloads these from Nexus Mods ("*"Virtual Atelier 1.6.4, A.G.I.S. 1.2.1"*"Equipment EX 1.2.10"*"Curbside 1.0.1"* ]] && [ "$(fetched)" = 0 ] && [[ "$OUT" != *"found in"* ]] && [[ "$OUT" != *"which is not here"* ]] && [ "$BEFORE" = "$(snapshot "$H")" ]' "$OUT"
run install --yes --with-mods --with-equipment-ex
expect "every Nexus mod of the sets is downloaded, checked and installed; none is left to download by hand" '[ $RC = 0 ] && [[ "$OUT" == *"Nexus Mods: the file lists of $NEXUS_IDS mods fetched"* ]] && [[ "$OUT" == *"Nexus Mods: a Premium account'"'"'s key ($H/.config/nightcoop-linux/nexus-api-key)"* ]] && [ "$(fetched)" = "$NEXUS_N" ] && [[ "$OUT" != *"not found in"* ]] && [[ "$OUT" != *"is not installed"* ]] && [[ "$OUT" != *"which is not here"* ]]' "$OUT"
expect "the files the rules take, from among all the files Nexus Mods lists" '[ -f "$G/r6/scripts/EquipmentEx/EquipmentEx.reds" ] && [ ! -e "$G/r6/scripts/EquipmentEx/EquipmentEx.HideHubButtons.reds" ] && [ -f "$G/r6/scripts/virtual-atelier-full/Config.reds" ] && [ ! -e "$G/r6/scripts/VirtualAtelier" ] && [ -f "$G/archive/pc/mod/NoIntroVideos.archive" ] && [ ! -e "$G/r6/scripts/NoIntroVideos" ] && [ -f "$G/r6/scripts/AGIS/agis.reds" ] && [ ! -e "$G/r6/scripts/AGIS_BLACKWALL" ] && [ -f "$CETM/CyberDrift Light/init.lua" ] && [ -f "$G/archive/pc/mod/Katana_Pack_2.archive" ] && [ ! -e "$G/archive/pc/mod/Katana_Nagakiba.archive" ] && [ -f "$G/archive/pc/mod/TheCommunityPaletteProject_MLTemplateResource.archive" ] && [ -f "$G/r6/tweaks/scorpiontank/#_scorpion_zenitex_core_dependency.yaml" ] && grep -q "3.1" "$CETM/VehicleCustomizerSVE/init.lua"' "$OUT"
expect "the cache keeps the downloads used, and no others: not an archived release (No Intro Videos 0.6, without game folders), an old one, or a file the rules pass over" '[ "$(ls "$C/mods" | wc -l)" = "$((NEXUS_N + GITHUB_N))" ] && ! ls "$C/mods" | grep -q -e "0-6-1730000000" -e BLACKWALL -e "Intro Videos - redscript" -e "Atelier - Basic" -e Verdant -e Nagakiba -e BrowserExtensionExample -e "ITP Compatibility" -e HideHubButtons && [ ! -e "$C/incoming" ] && [ "$(ls "$C/nexus-api" | wc -l)" = "$NEXUS_IDS" ]' "$(ls "$C/mods" "$C")"
expect "the key is nowhere but in its file: not in the output, the cache, the records or the game folder" '[[ "$OUT" != *"$NKEY"* ]] && [ "$(grep -r -l -F -- "$NKEY" "$H" "$LIB" 2>/dev/null)" = "$H/.config/nightcoop-linux/nexus-api-key" ]' "$(grep -r -l -F -- "$NKEY" "$H" "$LIB" 2>/dev/null)"
run check
expect "check: the key is a Premium account's" '[[ "$OUT" == *"Nexus Mods API:"*"a Premium account'"'"'s key ($H/.config/nightcoop-linux/nexus-api-key): this script downloads the Nexus mods"* ]]' "$OUT"
run uninstall --yes
expect "uninstall puts the game folder back exactly" '[ $RC = 0 ] && [ "$PRISTINE_NAPI" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_NAPI") <(snapshot "$G"))"
# Equipment-EX alone, handed over changed in one byte, cut short, linked elsewhere than Nexus Mods, then as it is
newworld napieq native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"; C="$H/.cache/nightcoop-linux"; keyfile
cp "$EQL/download_link-bad.json" "$EQL/download_link.json"
run install --yes --with-equipment-ex
expect "a download that is not the file Nexus Mods lists (its MD5) is not installed or kept, and the file is linked to download by hand" '[ $RC = 0 ] && [[ "$OUT" == *"$EQ10 from Nexus Mods is not installed: no file on Nexus Mods has its MD5"* ]] && [ ! -e "$G/r6/scripts/EquipmentEx" ] && ! ls "$C/mods" | grep -q Equipment && [ ! -e "$C/incoming" ] && [[ "$OUT" == *"not downloaded from Nexus Mods (see above)"*"mods/6945?tab=files&file_id="[0-9]* ]]' "$OUT"
cp "$EQL/download_link-short.json" "$EQL/download_link.json"
run update --yes
expect "nor one cut short (its size)" '[ $RC = 0 ] && [[ "$OUT" == *"$EQ10 from Nexus Mods is not installed: it is "*" bytes, and Nexus Mods lists "* ]] && [ ! -e "$G/r6/scripts/EquipmentEx" ]' "$OUT"
cp "$EQL/download_link-elsewhere.json" "$EQL/download_link.json"
run update --yes
expect "a download link to a server other than those of Nexus Mods is not followed" '[ $RC = 0 ] && [[ "$OUT" == *"Equipment EX was not downloaded from Nexus Mods: Nexus Mods gave no download link on its own servers"* ]] && [ "$(fetched)" = 0 ]' "$OUT"
cp "$EQL/download_link-good.json" "$EQL/download_link.json"
run update --yes
expect "the good file is downloaded, checked, installed and kept" '[ $RC = 0 ] && [[ "$OUT" == *"downloading $EQ10 ("*"B) from Nexus Mods"* ]] && [ "$(fetched)" = 1 ] && [ -f "$G/r6/scripts/EquipmentEx/EquipmentEx.reds" ] && [ -f "$C/mods/$EQ10" ] && [ ! -e "$C/incoming" ]' "$OUT"
stamps() { stat -c '%n %Y' "$C/nexus-api"/*; }
LISTS="$(stamps)"
run update --yes
expect "a rerun downloads nothing, and asks Nexus Mods only what changed lately, not for every file list" '[ $RC = 0 ] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]] && [ "$(fetched)" = 0 ] && [[ "$OUT" != *"file lists of"* ]] && [ "$LISTS" = "$(stamps)" ]' "$OUT"
# Equipment-EX 1.2.11 comes out, and updated.json names the mod
cp "$API/6945/files.json" "$T/eqex-files.json"; cp "$FIX/nexusapi/later/6945.files.json" "$API/6945/files.json"
updated() { printf '%s' "$1" > "$API/updated.json?period=1d"; printf '%s' "$1" > "$API/updated.json"; }   # Python 3.14 drops a file:// URL's query
updated "$(printf '[{"mod_id": 6945, "latest_file_update": %s, "latest_mod_activity": %s}]' "$(date +%s)" "$(date +%s)")"
run update --yes
expect "a new release on Nexus Mods is downloaded and installed by the next run, its file list alone fetched again" '[ $RC = 0 ] && [[ "$OUT" == *"Nexus Mods: the file lists of 1 mod fetched"* ]] && [[ "$OUT" == *"downloading $EQ11 ("* ]] && [ "$(fetched)" = 1 ] && grep -q "Lt7Qw2zXa" "$G/r6/scripts/EquipmentEx/EquipmentEx.reds" && [ -f "$C/mods/$EQ11" ] && [ ! -e "$C/mods/$EQ10" ]' "$OUT"
cp "$T/eqex-files.json" "$API/6945/files.json"; updated '[]'

section "Nexus Mods API: a key without Premium, and how the key is given"
newworld napifree native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
cp "$FIX/nexusapi/v1/users/validate-free.json" "$FIX/nexusapi/v1/users/validate.json"
mkdir -p "$T/xdg-spy"; printf '#!/bin/sh\nenv > "%s/spied-env"\necho "$HOME/Downloads"\n' "$T" > "$T/xdg-spy/xdg-user-dir"; chmod +x "$T/xdg-spy/xdg-user-dir"
RUNENV=(NEXUS_API_KEY="$NKEY"); PATH="$T/xdg-spy:$PATH" run install --yes --with-equipment-ex; RUNENV=()
expect "the key in NEXUS_API_KEY is not passed on to what the script starts" '[ -s "$T/spied-env" ] && ! grep -q -F -e NEXUS_API_KEY -e NIGHTCOOP_NEXUS_KEY -e "$NKEY" "$T/spied-env"' "$(cat "$T/spied-env")"
expect "NEXUS_API_KEY of an account without Premium: nothing is downloaded from Nexus Mods, and each file to download is linked" '[ $RC = 0 ] && [[ "$OUT" == *"The Nexus Mods account of the API key (NEXUS_API_KEY) is not Premium"* ]] && [ "$(fetched)" = 0 ] && [[ "$OUT" == *"Equipment EX (the main file, not the Hide Hub Buttons patch): https://www.nexusmods.com/cyberpunk2077/mods/6945?tab=files&file_id="[0-9]* ]] && [ ! -e "$G/r6/scripts/EquipmentEx" ] && [[ "$OUT" != *"$NKEY"* ]]' "$OUT"
RUNENV=(NEXUS_API_KEY="$NKEY"); run check; RUNENV=()
expect "check: the key's account is not Premium" '[[ "$OUT" == *"Nexus Mods API:"*"the key of an account without Premium (NEXUS_API_KEY): the Nexus mods are downloaded by hand"* ]]' "$OUT"
cp "$FIX/nexusapi/v1/users/validate-premium.json" "$FIX/nexusapi/v1/users/validate.json"
newworld napikeys native; OSR="$T/os-arch"; D="$H/Downloads"; mkdir -p "$D"
run install --yes --with-equipment-ex
expect "without a key, the list of what to download says how a Premium member lets the script do it" '[ $RC = 0 ] && [[ "$OUT" == *"which lets scripts"*"download only for Premium members (--save-nexus-key)"* ]] && [[ "$OUT" == *"mods/6945?tab=files"* ]] && [[ "$OUT" != *"file_id="* ]]' "$OUT"
run check
expect "check: no key" '[[ "$OUT" == *"Nexus Mods API:"*"no key: the Nexus mods are downloaded by hand (with a Premium account, --save-nexus-key lets this script do it)"* ]]' "$OUT"
run update --yes --save-nexus-key < /dev/null
expect "--save-nexus-key asks on a terminal only" '[ $RC != 0 ] && [[ "$OUT" == *"--save-nexus-key asks for the key on a terminal"* ]] && [ ! -e "$H/.config/nightcoop-linux/nexus-api-key" ]' "$OUT"
run update --yes --nexus-key-file "$H/no-such-key"
expect "a --nexus-key-file that is not there stops the run" '[ $RC != 0 ] && [[ "$OUT" == *"--nexus-key-file: there is no readable file $H/no-such-key"* ]]' "$OUT"
keyfile 600 'not a key!'
run update --yes
expect "a key file that holds no key is not used" '[ $RC = 0 ] && [[ "$OUT" == *"the Nexus Mods API key in $H/.config/nightcoop-linux/nexus-api-key does not look like one"* ]] && [[ "$OUT" != *"file_id="* ]]' "$OUT"
keyfile 644
run update --yes --no-nexus-api
expect "--no-nexus-api: the key is not used, nor even read" '[ $RC = 0 ] && [[ "$OUT" != *"Premium account"* ]] && [[ "$OUT" != *"can be read by other users"* ]] && [ ! -e "$G/r6/scripts/EquipmentEx" ] && [[ "$OUT" == *"(--save-nexus-key)"* ]]' "$OUT"
mv "$FIX/nexusapi/v1/users/validate.json" "$T/validate.json"
run update --yes
expect "a key file others can read is used with a warning; an API that does not answer leaves the downloads to you" '[ $RC = 0 ] && [[ "$OUT" == *"$H/.config/nightcoop-linux/nexus-api-key can be read by other users: make it yours alone (chmod 600"* ]] && [[ "$OUT" == *"Nexus Mods API: Nexus Mods did not answer as its API does (404); the Nexus mods are taken from your downloads only"* ]] && [ ! -e "$G/r6/scripts/EquipmentEx" ]' "$OUT"
mv "$T/validate.json" "$FIX/nexusapi/v1/users/validate.json"
cp "$H/.config/nightcoop-linux/nexus-api-key" "$H/my-key"; rm "$H/.config/nightcoop-linux/nexus-api-key"
mkdir -p "$T/spy"; printf '#!/bin/sh\nenv > "%s/spied-numfmt"\nexec "%s" "$@"\n' "$T" "$(command -v numfmt)" > "$T/spy/numfmt"; chmod +x "$T/spy/numfmt"
PATH="$T/spy:$PATH" run update --yes --nexus-key-file "$H/my-key"   # numfmt sizes a download, after the API's answers
expect "the key is not passed on to what the script starts while it uses the API either" '[ -s "$T/spied-numfmt" ] && ! grep -q -F -e NIGHTCOOP_NEXUS_KEY -e "$NKEY" "$T/spied-numfmt"' "$(cat "$T/spied-numfmt" 2>/dev/null)"
expect "--nexus-key-file: Equipment-EX comes from Nexus Mods" '[ $RC = 0 ] && [[ "$OUT" == *"a Premium account'"'"'s key ($H/my-key)"* ]] && [[ "$OUT" == *"downloading $EQ10 ("*"B) from Nexus Mods"* ]] && [ -f "$G/r6/scripts/EquipmentEx/EquipmentEx.reds" ] && [[ "$OUT" != *"not found in"* ]]' "$OUT"

# ------------------------------------------------- Cyber Engine Tweaks ----
section "Cyber Engine Tweaks installed alongside"
newworld cet native cet; OSR="$T/os-arch"
run install --yes --keep-other-mods
expect "version.dll override added too" '[ $RC = 0 ] && [ "$(hp reg-get "$PFX/user.reg" "$REG_KEY" version)" = native,builtin ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm,version=n,b\\\" %command% --launcher-skip" ]' "$OUT"

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
expect "CachyOS: game-performance goes in right before %command%; MangoHud only when asked; the line is replaced whole" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" game-performance %command% --launcher-skip" ] && [[ "$OUT" == *"game-performance found: the game will run in the performance power profile"* ]] && [[ "$OUT" == *"MangoHud is installed: --mangohud shows its overlay in the game"* ]]' "$OUT"
run install --yes --mangohud
expect "--mangohud adds MANGOHUD=1 after the DLL overrides" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" MANGOHUD=1 game-performance %command% --launcher-skip" ] && [[ "$OUT" == *"MANGOHUD=1 shows its overlay"* ]]' "$OUT"
run install --yes
expect "a later run keeps both (MangoHud without --mangohud too) and has nothing to do" '[ $RC = 0 ] && [[ "$(launch_opts)" == *"MANGOHUD=1 game-performance %command%"* ]] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run check
expect "check: both in use" '[[ "$OUT" == *"game-performance:"*"in the launch options"* ]] && [[ "$OUT" == *"MangoHud:"*"in the launch options"* ]] && [[ "$OUT" != *"will not start"* ]]' "$OUT"
run install --yes --no-mangohud --no-game-performance
expect "--no-mangohud and --no-game-performance take both out" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [[ "$OUT" == *"game-performance: taken out of the launch options"* ]] && [[ "$OUT" == *"MangoHud: taken out of the launch options"* ]]' "$OUT"
run install --yes
expect "--no-game-performance is remembered" '[ $RC = 0 ] && [[ "$(launch_opts)" != *game-performance* ]] && [[ "$OUT" == *"game-performance: left out of the launch options"* ]] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run install --yes --dry-run --game-performance
run install --yes
expect "a dry run does not change what is remembered" '[[ "$(launch_opts)" != *game-performance* ]]' "$(launch_opts)"
run install --yes --game-performance
expect "--game-performance puts it back" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" game-performance %command% --launcher-skip" ]' "$(launch_opts)"
set_lo "gamescope -W 1920 -H 1080 -- %command%"
run install --yes --mangohud
expect "a gamescope wrapper is replaced too, so MangoHud and game-performance go in" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" MANGOHUD=1 game-performance %command% --launcher-skip" ] && [[ "$OUT" != *"gamescope"* ]]' "$OUT"

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
expect "Arch without MangoHud: --mangohud says how to install it; other wrappers go" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [[ "$OUT" == *"MangoHud is not added: it is not installed (sudo pacman -S mangohud)"* ]]' "$OUT"
set_lo "mangohud %command%"
run check
expect "check: the mangohud wrapper without MangoHud stops the game" '[[ "$OUT" == *"MangoHud:"*"in the launch options, but it is not installed (sudo pacman -S mangohud)"* ]] && [[ "$OUT" == *"install MangoHud, or run"*"with Steam closed to take it out"* ]]' "$OUT"
run install --yes --mangohud
expect "--mangohud with the wrapper but no MangoHud: taken out, saying why" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [[ "$OUT" == *"MangoHud: taken out of the launch options: it is not installed (sudo pacman -S mangohud)"* ]] && [[ "$OUT" != *"already in the launch options"* ]]' "$OUT"
set_lo "mangohud %command%"
run install --yes
expect "a plain run takes it out too" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [[ "$OUT" == *"MangoHud: taken out of the launch options: it is not installed"* ]]' "$OUT"
set_lo "mangohud %command%"
run install --yes --no-mangohud
expect "--no-mangohud takes the wrapper out" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ]' "$(launch_opts)"

# ---------------------------------------------------------------- REDmod ----
section "REDmod: -modded only with --redmod, which is remembered"
newworld redmod native; OSR="$T/os-arch"
set_lo "gamemoderun %command% -modded"
run install --yes
expect "an earlier -modded goes with the rest of the line, and the run says how to keep it" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [[ "$OUT" == *"the launch options had -modded, which REDmod mods need"* ]] && [[ "$OUT" == *"Run this again with --redmod to keep it"* ]]' "$OUT"
mkdir -p "$G/mods/Some REDmod"; printf '{"name": "Some REDmod", "version": "1.0"}\n' > "$G/mods/Some REDmod/info.json"
mkdir -p "$G/mods/not a REDmod"; printf 'notes\n' > "$G/mods/not a REDmod/readme.txt"
run check
expect "check: a REDmod mod in mods/ (a folder with info.json) without -modded is named, with the option" '[[ "$OUT" == *"REDmod:"*"1 mod(s) in mods/, which load only with -modded"*"--redmod"* ]]' "$OUT"
run install --yes --keep-other-mods   # by default an install clears mods/ with the other mods, unless --redmod
expect "install says so too, and leaves the line as it is" '[ $RC = 0 ] && [[ "$OUT" == *"REDmod: 1 mod(s) in the game'"'"'s mods folder load only with -modded; --redmod adds it"* ]] && [[ "$(launch_opts)" != *-modded* ]]' "$OUT"
run install --yes --redmod
expect "--redmod puts -modded after --launcher-skip; without the REDmod DLC, it says to install it" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip -modded" ] && [[ "$OUT" == *"REDmod: -modded goes in the launch options"* ]] && [[ "$OUT" == *"install the free REDmod DLC in Steam"* ]]' "$OUT"
run install --yes
expect "--redmod is remembered: a later run keeps -modded and has nothing to do" '[ $RC = 0 ] && [[ "$(launch_opts)" == *"%command% --launcher-skip -modded" ]] && [[ "$OUT" == *"everything is up to date; nothing to do"* ]]' "$OUT"
run check
expect "check: -modded in the launch options, the mod counted, the REDmod DLC missing" '[[ "$OUT" == *"REDmod:"*"-modded in the launch options; 1 mod(s) in mods/; the REDmod DLC is not installed"* ]]' "$OUT"
mkdir -p "$G/tools/redmod/bin"; printf 'MZ redmod' > "$G/tools/redmod/bin/redMod.exe"
run install --yes --no-launcher-skip
expect "with --no-launcher-skip, -modded alone follows %command%" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% -modded" ]' "$(launch_opts)"
set_lo "gamemoderun %command%"
run install --yes
expect "with the DLC there and the launcher skipped, the run says how REDmod mods get deployed" '[ $RC = 0 ] && [[ "$(launch_opts)" == *"--launcher-skip -modded" ]] && [[ "$OUT" == *"REDmod mods need a deploy after each change"* ]] && [[ "$OUT" == *"tools/redmod/bin/redMod.exe deploy"* ]] && [[ "$OUT" != *"install the free REDmod DLC"* ]]' "$OUT"
run check
expect "check: the REDmod DLC is installed" '[[ "$OUT" == *"REDmod:"*"-modded in the launch options; 1 mod(s) in mods/; the REDmod DLC is installed"* ]]' "$OUT"
run install --yes --no-redmod
expect "--no-redmod takes it out again" '[ $RC = 0 ] && [ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" %command% --launcher-skip" ] && [[ "$OUT" == *"REDmod: -modded taken out of the launch options (--no-redmod)"* ]] && [ ! -e "$H/.local/share/nightcoop-linux/settings.tsv" ]' "$OUT"
run install --yes --dry-run --redmod
run install --yes
expect "a dry run does not remember --redmod" '[ $RC = 0 ] && [[ "$(launch_opts)" != *-modded* ]]' "$(launch_opts)"
run install --yes --redmod --no-game-performance
run install --yes --game-performance
expect "--redmod and --no-game-performance are remembered side by side; one choice does not drop the other" '[ $RC = 0 ] && [[ "$(launch_opts)" == *"-modded" ]] && grep -q "^redmod" "$H/.local/share/nightcoop-linux/settings.tsv" && ! grep -q "^game-performance" "$H/.local/share/nightcoop-linux/settings.tsv"' "$(cat "$H/.local/share/nightcoop-linux/settings.tsv" 2>/dev/null)"

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
