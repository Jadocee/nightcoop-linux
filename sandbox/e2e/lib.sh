#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Helpers for the real-Proton sandbox scripts (source this file). They run Proton outside
# Steam the way the installer does, start the stand-in Cyberpunk2077.exe in a prefix and
# classify what RED4ext did:
#   started    RED4ext's log shows it initialising (the loader and the C++ runtime work)
#   error998   the loader's "RED4ext (error 998)" dialog: RED4ext.dll failed in DllMain
#   refused    RED4ext started but rejected the game patch ("ensure your game is updated")
#   notloaded  Wine used its own winmm.dll, so RED4ext's loader never ran
# A plain "RED4ext" dialog after a start is expected: the stand-in has none of the game
# code RED4ext hooks into, so RED4ext stops at that point.
#
# Variables set here are read by the scripts that source this file.
# shellcheck disable=SC2034

SRC="${SRC:-/src}"                                     # the repository, mounted read-only
NI="$SRC/nightcoop-install.sh"
WORK="${WORK:-$HOME/work}"                             # scratch space for this run
CACHE="${CACHE:-$HOME/.cache/nightcoop-sandbox}"       # downloads, kept between runs
PROTON_TOOL="${PROTON_TOOL:-proton-cachyos-native}"
PROTON="${PROTON:-/usr/share/steam/compatibilitytools.d/$PROTON_TOOL}"
APPID=1091500
REG_KEY='Software\Wine\AppDefaults\Cyberpunk2077.exe\DllOverrides'
NIGHTCOOP_SITE="${NIGHTCOOP_SITE:-https://nightcoop.net}"
VC2019_URL="https://aka.ms/vs/16/release/vc_redist.x64.exe"   # what Steam's first launch installs
VC2022_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
VC14_URL="https://aka.ms/vc14/vc_redist.x64.exe"              # what the installer prefers
EXTRA_ENV=()                                           # extra environment for Proton
DIALOG="" RESULT="" DETAIL="" RC=0

say() { printf '%s\n' "$*"; }
die() { printf 'sandbox: %s\n' "$*" >&2; exit 2; }
hp()  { bash "$NI" __py "$@"; }                        # the installer's own helper

start_display() {   # a virtual X display, so message boxes and installers behave as on a desktop
    export DISPLAY="${DISPLAY:-:99}"
    xwininfo -root >/dev/null 2>&1 && return 0
    Xvfb "$DISPLAY" -screen 0 1280x720x24 -nolisten tcp >/dev/null 2>&1 &
    local _
    for _ in $(seq 100); do xwininfo -root >/dev/null 2>&1 && return 0; sleep 0.1; done
    die "Xvfb did not start on $DISPLAY"
}

proton_cmd() {   # proton_cmd <compat dir> <verb> [args...] : Proton with the environment Steam gives it
    local compat="$1"; shift
    env STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_CLIENT:-$WORK/steam}" STEAM_COMPAT_DATA_PATH="$compat" \
        SteamAppId=$APPID SteamGameId=$APPID STEAM_COMPAT_APP_ID=$APPID PROTONFIXES_DISABLE=1 \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$PROTON/proton" "$@"
}
wine_idle() { WINEPREFIX="$1/pfx" "$PROTON/files/bin/wineserver" -w 2>/dev/null || true; }
wine_kill() { WINEPREFIX="$1/pfx" "$PROTON/files/bin/wineserver" -k 2>/dev/null || true; }

new_prefix() {   # new_prefix <compat dir> : a fresh Proton prefix, as Steam creates on first launch
    [ ! -e "$1" ] || die "refusing to reuse $1"
    mkdir -p "$1" "${STEAM_CLIENT:-$WORK/steam}"
    # getcompatpath sets the prefix up like "run" does, then only runs winepath: no steam.exe,
    # so no Steam client is needed.
    proton_cmd "$1" getcompatpath /tmp >"$1.log" 2>&1 || die "Proton could not create a prefix (see $1.log)"
    wine_idle "$1"
}
clone_prefix() { [ ! -e "$2" ] || die "refusing to reuse $2"; cp -a "$1" "$2"; }

run_win() {   # run_win <compat> <seconds> <log> <windows exe> [args...] : sets DIALOG and RC
    local compat="$1" t="$2" log="$3" pid _
    shift 3
    proton_cmd "$compat" runinprefix "$@" >"$log" 2>&1 &
    pid=$!; DIALOG=""
    for _ in $(seq "$t"); do
        kill -0 "$pid" 2>/dev/null || break
        DIALOG="$(xwininfo -root -tree 2>/dev/null | grep -o '"RED4ext[^"]*"\|"[^"]*[Ee]rror[^"]*"' | head -n1 | tr -d '"')"
        [ -n "$DIALOG" ] && break
        sleep 1
    done
    if [ -n "$DIALOG" ] || kill -0 "$pid" 2>/dev/null; then wine_kill "$compat"; fi   # a dialog, or a hang
    wait "$pid" 2>/dev/null; RC=$?
    wine_idle "$compat"
}

runtime_of() { hp pever "$1/pfx/drive_c/windows/system32/msvcp140.dll"; }

install_vc() {   # install_vc <compat> <installer> : Microsoft's installer, quietly, as the installer runs it
    run_win "$1" 600 "$1.vc.log" "$2" /install /quiet /norestart
    case "$RC" in 0|194|102) ;; *) say "    (Microsoft installer exit code $RC)" ;; esac
}

set_override() { hp reg-set "$1/pfx/user.reg" "$REG_KEY" winmm native,builtin; }

mkgame() {   # mkgame <dir> <stand-in exe> [archive...] : a game folder with the archives unpacked in order
    local dir="$1" exe="$2" a
    shift 2
    [ ! -e "$dir" ] || die "refusing to reuse $dir"
    mkdir -p "$dir/bin/x64"
    cp "$exe" "$dir/bin/x64/Cyberpunk2077.exe"
    for a in "$@"; do bsdtar -xf "$a" -C "$dir"; done
}

launch() {   # launch <compat> <game dir> : start the stand-in once; sets RESULT and DETAIL
    local compat="$1" game="$2" log mark winmm r4log
    local -a saved=(${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"})
    log="$game.launch-$(date +%s%N).log"; mark="$log.start"
    : > "$mark"
    EXTRA_ENV+=(WINEDEBUG=+loaddll)
    run_win "$compat" 90 "$log" "$game/bin/x64/Cyberpunk2077.exe" --launcher-skip
    EXTRA_ENV=(${saved[@]+"${saved[@]}"})
    # Wine's log doubles the backslashes: Loaded L"Z:\\...\\bin\\x64\\WINMM.dll" at ...: native
    winmm="$(grep -i -E 'Loaded .*bin\\+x64\\+winmm\.dll' "$log" | grep -o 'builtin\|native' | tail -n1)"
    r4log="$(find "$game/red4ext/logs" -name 'red4ext-*.log' -newer "$mark" 2>/dev/null | sort | tail -n1)"
    if [[ "$DIALOG" == *"error 998"* ]]; then RESULT=error998
    elif [ -n "$r4log" ] && grep -q 'ensure your game is updated' "$r4log"; then RESULT=refused
    elif [ -n "$r4log" ] && grep -q 'is initializing' "$r4log"; then RESULT=started
    elif [ "$winmm" != native ]; then RESULT=notloaded
    else RESULT=unknown; fi
    DETAIL="winmm.dll ${winmm:-not seen}"
    if [ -s "$r4log" ]; then DETAIL="$DETAIL, $(grep -o 'RED4ext (v[0-9.]*)' "$r4log" | head -n1)"
    elif [ -n "$r4log" ]; then DETAIL="$DETAIL, empty RED4ext log"; fi
    [ -z "$DIALOG" ] || DETAIL="$DETAIL, dialog \"$DIALOG\""
}

fetch() {   # fetch <url> <cache name> [sha256] [max age in minutes] : a cached download; prints its path
    local f="$CACHE/$2" age="${4:-10080}"
    mkdir -p "$CACHE"
    if [ ! -s "$f" ] || [ -n "$(find "$f" -mmin +"$age" 2>/dev/null)" ]; then
        curl -fsSL --retry 3 --connect-timeout 20 -o "$f.part" "$1" || die "download failed: $1"
        mv -f "$f.part" "$f"
    fi
    if [ -n "${3:-}" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$3" ]; then die "checksum mismatch: $1"; fi
    echo "$f"
}

nightcoop_for() {   # nightcoop_for <patch> : the archive nightcoop.net lists for that patch; prints its path
    local feed status ver url sha _
    feed="$(fetch "$NIGHTCOOP_SITE/releases.json" releases.json '' 60)"
    IFS=$'\x1f' read -r status ver url sha _ < <(hp pick "$feed" "$1" "$NIGHTCOOP_SITE")
    [ "$status" = ok ] && [ -n "$url" ] || die "nightcoop.net lists no build for game $1"
    say "    NightCoop $ver for game $1: $(basename "$url")" >&2
    fetch "$url" "$(basename "$url")" "$sha"
}

build_stubs() {   # build_stubs <dir> : the stand-in executables, one per game patch
    [ -f "$1/cp77-2.5.exe" ] || bash "$SRC/sandbox/e2e/stub/build.sh" "$1" >/dev/null
}
