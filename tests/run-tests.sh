#!/usr/bin/env bash
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
    -e "s#^VCREDIST_URLS=.*#VCREDIST_URLS=(\"file://$FIX/site/vc_redist.x64.exe\")#" "$SCRIPT" > "$NI"
chmod +x "$NI"
for os in steamos:SteamOS cachyos:CachyOS arch:Arch; do
    printf 'NAME="%s"\nPRETTY_NAME="%s"\nID=%s\nID_LIKE=arch\n' "${os#*:}" "${os#*:}" "${os%%:*}" > "$T/os-${os%%:*}"
done

H="" OSR="$T/os-steamos" OUT=""
run() {   # run <args...> : output in $OUT, status in $RC
    OUT="$(env -i PATH="$PATH" HOME="$H" LANG=C.UTF-8 DISPLAY=:0 NIGHTCOOP_ALLOW_ROOT=1 \
           NIGHTCOOP_OS_RELEASE="$OSR" bash "$NI" "$@" 2>&1)"; RC=$?
}
hp() { bash "$SCRIPT" __py "$@"; }
newworld() {   # newworld <name> <layout>
    H="$T/$1"; python3 -I "$HERE/mkfixtures.py" world "$H" "$FIX" "$2"
    if [ "$2" = flatpak ]; then STEAM="$H/.var/app/com.valvesoftware.Steam/.local/share/Steam"; LIB="$STEAM"
    else STEAM="$H/.local/share/Steam"; LIB="$H/sdcard"; fi
    G="$LIB/steamapps/common/Cyberpunk 2077"
    PFX="$LIB/steamapps/compatdata/1091500/pfx"
    LC="$STEAM/userdata/12345/config/localconfig.vdf"
}
snapshot() { (cd "$1" && find . -print | sort && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
launch_opts() { sed -n 's/.*"LaunchOptions"[[:space:]]*"\(.*\)"$/\1/p' "$LC"; }
REG_KEY='Software\Wine\AppDefaults\Cyberpunk2077.exe\DllOverrides'

# ---------------------------------------------------------------- helpers ----
section "Launch option merging"
lo() { hp lo-merge "$1" | cut -d$'\x1f' -f"$2"; }
expect "empty"                       '[ "$(lo "" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" ]'
expect "arguments only"              '[ "$(lo "--launcher-skip" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command% --launcher-skip" ]'
expect "CachyOS wrapper kept"        '[ "$(lo "game-performance %command%" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" game-performance %command%" ]'
expect "other overrides kept"        '[ "$(lo "WINEDLLOVERRIDES=\"version=n,b\" %command%" 2)" = "WINEDLLOVERRIDES=\"version=n,b;winmm=n,b\" %command%" ]'
expect "builtin winmm corrected"     '[ "$(lo "WINEDLLOVERRIDES=winmm=b mangohud %command%" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" mangohud %command%" ]'
expect "combined entry recognised"   '[ "$(lo "WINEDLLOVERRIDES=\"winmm,version=n,b\" %command%" 1)" = ok ]'
expect "override after %command%"    '[ "$(lo "%command% WINEDLLOVERRIDES=winmm=n,b" 1)" = broken ]'
expect "moved before %command%"      '[ "$(lo "%command% WINEDLLOVERRIDES=winmm=n,b" 2)" = "WINEDLLOVERRIDES=\"winmm=n,b\" %command%" ]'

section "Release selection (releases.json)"
pick() { hp pick "$FIX/site/releases.json" "$1" "https://nightcoop.net" "${2:-}" | tr '\037' '|'; }
expect "2.5 matches the 2.50 archive" '[[ "$(pick 2.5,2.5.0.0)" == "ok|0.1.2-beta|https://nightcoop.net/files/NightCoop-0.1.2-beta-2.5.zip|"*"|2.50|3|1.30.0|1|0" ]]'
expect "2.6 picks the newest build"   '[[ "$(pick 2.6)" == ok\|0.1.3-beta\|*\|1\|0 ]]'
expect "unknown game falls back"      '[[ "$(pick 9.9)" == ok\|0.1.3-beta\|*\|0\|0 ]]'
expect "local archive identified"     '[[ "$(pick 2.5 "$(sha256sum "$FIX/site/files/NightCoop-0.1.2-beta-2.5.zip" | cut -d" " -f1)")" == match\|0.1.2-beta\|* ]]'
expect "yanked build flagged"         '[[ "$(pick 2.5 "$(printf 2%.0s {1..64})")" == match\|0.1.1-beta\|*\|1 ]]'
expect "broken JSON reported"         '[[ "$(hp pick /dev/null 2.5 x)" == error* ]]'

section "Archive safety and versions"
expect "path traversal refused"       '! hp unzip "$FIX/evil.zip" "$T/evil" 2>/dev/null && [ ! -e "$T/escape.txt" ]'
expect "version compare pads"         'hp vge 1.31 1.31.0 && hp vge 14.51.36247.0 14.51 && ! hp vge 14.44.35211.0 14.51'

# ------------------------------------------------- SteamOS, game on SD card ----
section "SteamOS: game on an SD card library"
newworld deck native; OSR="$T/os-steamos"
PRISTINE_GAME="$(snapshot "$G")"; PRISTINE_SYS32="$(snapshot "$PFX/drive_c/windows/system32")"; PRISTINE_LO="$(launch_opts)"
run check
expect "check finds game on SD card"  '[ $RC = 0 ] && [[ "$OUT" == *"game folder: $LIB/"* ]] && [[ "$OUT" == *"NightCoop:"*"not installed"* ]]' "$OUT"
expect "check flags the old runtime"  '[[ "$OUT" == *"14.28.29913.0 (too old"* ]]' "$OUT"
expect "check offers the SteamOS protontricks route" '[[ "$OUT" == *"Discover: install \"Protontricks\""* ]]' "$OUT"
BEFORE="$(snapshot "$H")"
run install --dry-run
expect "dry run succeeds"             '[ $RC = 0 ] && [[ "$OUT" == *"dry run finished"* ]]' "$OUT"
expect "dry run changes nothing"      '[ "$BEFORE" = "$(snapshot "$H")" ]'

run install --yes
expect "install succeeds"             '[ $RC = 0 ]' "$OUT"
expect "NightCoop in existing Plugins folder (no case duplicate)" '[ -f "$G/red4ext/Plugins/NightCoop/NightCoop.dll" ] && [ ! -e "$G/red4ext/plugins" ]'
expect "other plugin untouched"       '[ -f "$G/red4ext/Plugins/OtherMod/other.dll" ]'
expect "RED4ext 1.31 replaced bundled 1.30" '[ "$(hp pever "$G/red4ext/RED4ext.dll" product)" = 1.31.0 ] && [ "$(hp pever "$G/bin/x64/winmm.dll" product)" = 1.31.0 ]'
expect "README not copied"            '[ ! -e "$G/README.txt" ]'
expect "runtime upgraded to 14.51"    '[ "$(hp pever "$PFX/drive_c/windows/system32/msvcp140.dll")" = 14.51.36247.0 ]'
expect "newest installer chosen over Steamworks 14.44" '[[ "$OUT" == *"installer: $H/.cache/nightcoop-linux/vc_redist.x64.exe (14.51.36247.0)"* ]]' "$OUT"
expect "registry override written"    '[ "$(hp reg-get "$PFX/user.reg" "$REG_KEY" winmm)" = native,builtin ]'
expect "launch options merged"        '[ "$(launch_opts)" = "WINEDLLOVERRIDES=\\\"winmm=n,b\\\" game-performance %command% --launcher-skip" ]' "$(launch_opts)"
expect "saves backed up"              '[ -f "$(ls -d "$H"/.local/share/nightcoop-linux/backups/*/)Saved Games/ManualSave-0/sav.dat" ]'
expect "check reports NightCoop"      '[[ "$OUT" == *"NightCoop:"*"0.1.2.0"*"release 0.1.2-beta"* ]]' "$OUT"
NRUNS="$(wc -l < "$PFX/../fake-proton.log")"

run install --yes
expect "second install succeeds"      '[ $RC = 0 ]' "$OUT"
expect "runtime not reinstalled"      '[ "$(wc -l < "$PFX/../fake-proton.log")" = "$NRUNS" ] && [[ "$OUT" == *"runtime 14.51.36247.0 is new enough"* ]]' "$OUT"
expect "overrides recognised"         '[[ "$OUT" == *"registry already has winmm"* ]] && [[ "$OUT" == *"launch options already contain"* ]]' "$OUT"

V1_GAME="$(snapshot "$G")"
run install --yes --nightcoop-zip "$FIX/NightCoop-0.1.3-test.zip"
expect "unlisted local archive installs with a warning" '[ $RC = 0 ] && [[ "$OUT" == *"not listed on"* ]]' "$OUT"
expect "bundled newer RED4ext 1.32 kept" '[ "$(hp pever "$G/red4ext/RED4ext.dll" product)" = 1.32.0 ] && [[ "$OUT" == *"using RED4ext 1.32.0 from the NightCoop archive"* ]]' "$OUT"
expect "files dropped by the new build removed" '[ ! -e "$G/red4ext/Plugins/NightCoop/legacy.dll" ] && [ ! -e "$G/archive/pc/mod/NightCoop.archive" ] && [[ "$OUT" == *"2 stale removed"* ]]' "$OUT"
expect "RED4ext licence files protected from stale removal" '[ -f "$G/red4ext/LICENSE.txt" ]'
expect "backslash paths unpacked"     '[ "$(hp pever "$G/red4ext/Plugins/NightCoop/NightCoop.dll")" = 0.1.3.0 ]'

run restore --yes
expect "restore succeeds"             '[ $RC = 0 ]' "$OUT"
expect "restore returns the previous build" '[ "$V1_GAME" = "$(snapshot "$G")" ]' "$(diff <(echo "$V1_GAME") <(snapshot "$G"))"

run uninstall --yes
expect "uninstall succeeds"           '[ $RC = 0 ] && [[ "$OUT" == *"install(s) undone"* ]]' "$OUT"
expect "game folder byte-identical to before" '[ "$PRISTINE_GAME" = "$(snapshot "$G")" ]' "$(diff <(echo "$PRISTINE_GAME") <(snapshot "$G"))"
expect "prefix runtime restored"      '[ "$PRISTINE_SYS32" = "$(snapshot "$PFX/drive_c/windows/system32")" ]'
expect "registry override removed"    '! hp reg-get "$PFX/user.reg" "$REG_KEY" winmm >/dev/null'
expect "launch options left as they are" '[ "$(launch_opts)" != "$PRISTINE_LO" ]'
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
kill "$STEAM_PID" 2>/dev/null; wait "$STEAM_PID" 2>/dev/null
expect "install succeeds with Steam open" '[ $RC = 0 ]' "$OUT"
expect "launch options not touched"   '[ "$(launch_opts)" = "game-performance %command% --launcher-skip" ]'
expect "registry override still set"  '[ "$(hp reg-get "$PFX/user.reg" "$REG_KEY" winmm)" = native,builtin ]'
expect "optional step suggested"      '[[ "$OUT" == *"Optional:"*"WINEDLLOVERRIDES=\"winmm=n,b\" game-performance %command% --launcher-skip"* ]]' "$OUT"
expect "no 'manual step' demanded"    '[[ "$OUT" != *"One manual step left"* ]]' "$OUT"

# ---------------------------------------------------------- Flatpak Steam ----
section "Flatpak Steam (sandbox paths in Steam's files)"
newworld flat flatpak; OSR="$T/os-arch"
run check
expect "Flatpak root detected"        '[ $RC = 0 ] && [[ "$OUT" == *"Steam (flatpak client): $STEAM"* ]]' "$OUT"
expect "sandbox config_info path mapped to the host" '[[ "$OUT" == *"Proton: Proton - Experimental"*"prefix'"'"'s last launch"* ]]' "$OUT"
run install --yes
expect "install succeeds"             '[ $RC = 0 ] && [ -f "$G/red4ext/Plugins/NightCoop/NightCoop.dll" ]' "$OUT"

# ------------------------------------------------- CachyOS, proton-cachyos ----
section "CachyOS: proton-cachyos chosen in Steam, game never relaunched"
newworld cachy cachyos; OSR="$T/os-cachyos"
run check
expect "compatibility tool resolved from Steam's setting" '[[ "$OUT" == *"Proton: proton-cachyos"*"Steam setting \"proton-cachyos\""* ]]' "$OUT"
expect "pacman hint for vm.max_map_count" '[[ "$OUT" != *"vm.max_map_count is"* ]] || [[ "$OUT" == *"sudo tee /etc/sysctl.d"* ]]' "$OUT"

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
