#!/usr/bin/env bash
# nightcoop-bazzite-install.sh
#
# Installs the NightCoop co-op mod for Cyberpunk 2077 on Bazzite (and other
# Linux systems running the native Steam client with Proton), and fixes the two
# things that break it out of the box on Linux:
#
#   1. The NightCoop archive bundles RED4ext 1.30, which does not work on game
#      patch 2.5 (newer 2.5 builds bundle 1.31). This script overlays RED4ext 1.31 either way.
#   2. Proton's prefix ships a 2020 copy of the Microsoft C++ runtime. RED4ext is
#      built with a 2026 toolset and crashes inside that old runtime with
#      "RED4ext (error 998) No access to memory location". This script installs
#      the Visual C++ 2022 runtime into the game's Proton prefix.
#
# It also makes sure Steam launches the game with the DLL override that lets
# Proton load RED4ext's winmm.dll loader.
#
# Usage:
#   ./nightcoop-bazzite-install.sh [install] [options]  install, or update to the latest build (default)
#   ./nightcoop-bazzite-install.sh check                report current state and whether an update exists
#   ./nightcoop-bazzite-install.sh restore <backupdir>  put back files replaced by an earlier install
#
# Running it again on a machine where the mod is already installed compares the
# installed build with the latest one on nightcoop.net and updates only when they
# differ; when everything is current it changes nothing.
#
# Options for install:
#   --nightcoop-zip FILE   use an already-downloaded NightCoop-<version>.zip
#   --red4ext-zip FILE     use an already-downloaded red4ext-1.31.0.zip
#   --vcredist FILE        use an already-downloaded VC_redist.x64.exe
#   --force                reinstall the mod files even when they are already the latest
#   --backup-saves         copy the save folder (default on a first install)
#   --no-save-backup       do not copy the save folder (default on an update)
#   --dry-run              detect and verify everything, change nothing
#   --yes                  do not ask for confirmation
#
# Requirements: bash, curl, python3, unzip, sha256sum (all present on Bazzite).

set -euo pipefail

APPID=1091500
RED4EXT_VER="1.31.0"
RED4EXT_URL="https://github.com/wopss/RED4ext/releases/download/v${RED4EXT_VER}/red4ext-${RED4EXT_VER}.zip"
RED4EXT_SHA="b9ae4351f547f90af58dfbf7445d45c55cd5ba24fbee27fb16fb5d91e9df621e"
NIGHTCOOP_SITE="https://nightcoop.net"
VCREDIST_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
MIN_RUNTIME="14.44"          # RED4ext 1.31 is linked with toolset 14.44
LAUNCH_OPTS='WINEDLLOVERRIDES="winmm=n,b" %command%'

MODE="install"
NIGHTCOOP_ZIP=""
RED4EXT_ZIP=""
VCREDIST=""
SAVE_BACKUP=""      # 1 / 0 / "" = decide (first install: yes, update: no)
FORCE=0
DRY_RUN=0
ASSUME_YES=0
RESTORE_DIR=""

# ---------------------------------------------------------------- helpers ----
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
ok()    { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m[!!]\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m[XX]\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    local a
    read -r -p "  $1 [y/N] " a
    [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]]
}

need_tool() { command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"; }

# Version strings from a PE file (exe/dll): "file" or "product".
pe_version() {   # pe_version <file> file|product
    python3 -I - "$1" "$2" <<'PY'
import re, struct, sys
data = open(sys.argv[1], 'rb').read()
want = sys.argv[2]
key = b'ProductVersion' if want == 'product' else b'FileVersion'
needle = key.decode().encode('utf-16le') + b'\0\0'
m = re.search(re.escape(needle), data)
if m:
    i = m.end()
    while data[i:i+2] == b'\0\0':
        i += 2
    j = data.index(b'\0\0', i)
    # make sure we cut on a UTF-16 boundary
    while (j - i) % 2:
        j = data.index(b'\0\0', j + 1)
    s = data[i:j].decode('utf-16le', 'ignore').strip('\0 ')
    if s:
        print(s); sys.exit(0)
# fall back to the fixed-info block
m = re.search(b'\xbd\x04\xef\xfe', data)
if m:
    off = m.start()
    ms, ls = struct.unpack_from('<II', data, off + (8 if want == 'file' else 16))
    print('%d.%d.%d.%d' % (ms >> 16, ms & 0xffff, ls >> 16, ls & 0xffff)); sys.exit(0)
print('')
PY
}

ver_ge() {   # ver_ge A B : true if dotted version A >= B
    python3 -I - "$1" "$2" <<'PY'
import sys
def t(v): return tuple(int(x) for x in ''.join(c if c.isdigit() or c == '.' else ' ' for c in v).split()[0].split('.')) if v.strip() else (0,)
sys.exit(0 if t(sys.argv[1]) >= t(sys.argv[2]) else 1)
PY
}

sha_check() {   # sha_check <file> <sha256>
    echo "$2  $1" | sha256sum -c - >/dev/null 2>&1
}

download() {    # download <url> <dest>
    info "downloading $(basename "$2") from $1"
    curl -fL --retry 3 --connect-timeout 20 -o "$2" "$1"
}

game_running() { pgrep -x 'Cyberpunk2077.e' >/dev/null 2>&1; }
steam_running() { pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1; }

# ---------------------------------------------------------- argument parse ----
if [ $# -gt 0 ]; then
    case "$1" in
        install|update) MODE=install; shift ;;
        check|restore) MODE="$1"; shift ;;
        -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    esac
fi
if [ "$MODE" = restore ]; then
    [ $# -ge 1 ] || fail "restore needs the backup directory as argument"
    RESTORE_DIR="$1"; shift
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --nightcoop-zip) NIGHTCOOP_ZIP="$2"; shift 2 ;;
        --red4ext-zip)   RED4EXT_ZIP="$2"; shift 2 ;;
        --vcredist)      VCREDIST="$2"; shift 2 ;;
        --no-save-backup) SAVE_BACKUP=0; shift ;;
        --backup-saves)  SAVE_BACKUP=1; shift ;;
        --force)         FORCE=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --yes|-y)        ASSUME_YES=1; shift ;;
        -h|--help)       sed -n '2,38p' "$0"; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

[ "$(id -u)" != 0 ] || fail "run this as your normal user, not root"
for t in curl python3 unzip sha256sum; do need_tool "$t"; done

# ------------------------------------------------------------ find things ----
bold "Locating Steam and Cyberpunk 2077"

STEAM_ROOT=""
for c in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
    if [ -d "$c/steamapps" ]; then STEAM_ROOT="$(readlink -f "$c")"; break; fi
done
if [ -z "$STEAM_ROOT" ] && [ -d "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps" ]; then
    fail "only the Flatpak Steam was found. This script supports the native Steam client that Bazzite ships. For Flatpak Steam, install the mod files by hand and run: flatpak run com.github.Matoking.protontricks $APPID --force vcrun2022"
fi
[ -n "$STEAM_ROOT" ] || fail "Steam installation not found under ~/.local/share/Steam"
ok "Steam root: $STEAM_ROOT"

# every library folder, from libraryfolders.vdf plus the root itself
mapfile -t LIBS < <(
    { echo "$STEAM_ROOT"
      [ -f "$STEAM_ROOT/steamapps/libraryfolders.vdf" ] && \
        grep -oE '"path"[[:space:]]+"[^"]+"' "$STEAM_ROOT/steamapps/libraryfolders.vdf" | sed -E 's/"path"[[:space:]]+"//; s/"$//; s/\\\\/\//g'
    } | awk '!seen[$0]++'
)

GAME_LIB=""; GAME_DIR=""
for lib in "${LIBS[@]}"; do
    if [ -f "$lib/steamapps/common/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe" ]; then
        GAME_LIB="$lib"; GAME_DIR="$lib/steamapps/common/Cyberpunk 2077"; break
    fi
done
[ -n "$GAME_DIR" ] || fail "Cyberpunk 2077 is not installed in any Steam library (looked in: ${LIBS[*]})"
ok "Game folder: $GAME_DIR"

NC_DLL="$GAME_DIR/red4ext/plugins/NightCoop/NightCoop.dll"
STATE_FILE="$GAME_DIR/red4ext/plugins/NightCoop/nightcoop-bazzite-installed.txt"   # what this script installed
GAME_VER="$(pe_version "$GAME_DIR/bin/x64/Cyberpunk2077.exe" product || true)"
[ -n "$GAME_VER" ] && ok "Game version: $GAME_VER" || warn "could not read the game version from the executable"

COMPAT="$GAME_LIB/steamapps/compatdata/$APPID"
PFX="$COMPAT/pfx"
SYS32="$PFX/drive_c/windows/system32"
SAVES="$PFX/drive_c/users/steamuser/Saved Games/CD Projekt Red/Cyberpunk 2077"

if [ ! -d "$SYS32" ]; then
    warn "no Proton prefix yet at $COMPAT"
    cat <<EOF

  The game has never been started with Proton on this PC. Do this first:
    1. In Steam: right-click Cyberpunk 2077 > Properties > Compatibility,
       tick "Force the use of a specific Steam Play compatibility tool"
       and pick "Proton Experimental".
    2. Launch the game once, wait for the main menu, then quit.
    3. Run this script again.
EOF
    exit 1
fi
ok "Proton prefix: $COMPAT"

# Which Proton does this prefix use? config_info names its font dir inside the Proton folder.
PROTON_DIR=""
if [ -f "$COMPAT/config_info" ]; then
    PROTON_DIR="$(grep -m1 '/files/share/fonts' "$COMPAT/config_info" | sed 's#/files/share/fonts.*##' || true)"
fi
if [ -z "$PROTON_DIR" ] || [ ! -x "$PROTON_DIR/proton" ]; then
    for c in "$STEAM_ROOT/steamapps/common/Proton - Experimental" "$STEAM_ROOT"/compatibilitytools.d/GE-Proton* "$STEAM_ROOT"/steamapps/common/Proton*; do
        [ -x "$c/proton" ] && PROTON_DIR="$c" && break
    done
fi
[ -n "$PROTON_DIR" ] && [ -x "$PROTON_DIR/proton" ] || fail "could not find the Proton that runs this game"
ok "Proton: $(basename "$PROTON_DIR")"

# ------------------------------------------------------------- state read ----
runtime_version() { [ -f "$SYS32/msvcp140.dll" ] && pe_version "$SYS32/msvcp140.dll" file || echo ""; }
red4ext_version() { [ -f "$GAME_DIR/red4ext/RED4ext.dll" ] && pe_version "$GAME_DIR/red4ext/RED4ext.dll" product || echo ""; }

launch_options_status() {   # prints: ok | missing | nosteamconfig
    local f found=0 good=0
    for f in "$STEAM_ROOT"/userdata/*/config/localconfig.vdf; do
        [ -f "$f" ] || continue
        found=1
        if python3 -I - "$f" "$APPID" <<'PY'
import sys, re
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
appid = sys.argv[2]
# tokenizer: quoted strings (with escapes), braces
tok = re.compile(r'"((?:[^"\\]|\\.)*)"|([{}])|//[^\n]*')
stack = []; prev = None; hit = False
for m in tok.finditer(text):
    if m.group(2) == '{':
        stack.append((prev or '').lower()); prev = None
    elif m.group(2) == '}':
        if stack: stack.pop()
        prev = None
    elif m.group(1) is not None:
        s = m.group(1)
        if prev is not None and stack[-6:] == ['userlocalconfigstore','software','valve','steam','apps',appid] and prev.lower() == 'launchoptions':
            v = s.replace('\\"', '"').replace('\\\\', '\\')
            if 'winmm' in v and 'WINEDLLOVERRIDES' in v and '%command%' in v:
                hit = True
            prev = None
        else:
            prev = s
sys.exit(0 if hit else 1)
PY
        then good=1; fi
    done
    [ "$found" = 1 ] || { echo nosteamconfig; return; }
    [ "$good" = 1 ] && echo ok || echo missing
}

set_launch_options() {      # edits every localconfig.vdf; Steam must be closed
    local f
    for f in "$STEAM_ROOT"/userdata/*/config/localconfig.vdf; do
        [ -f "$f" ] || continue
        cp -a "$f" "$f.nightcoop-backup-$(date +%Y%m%d-%H%M%S)"
        python3 -I - "$f" "$APPID" "$LAUNCH_OPTS" <<'PY'
import sys, re
path, appid, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding='utf-8', errors='surrogateescape').read()
tok = re.compile(r'"((?:[^"\\]|\\.)*)"|([{}])|//[^\n]*')
want = ['userlocalconfigstore','software','valve','steam','apps']
stack = []; prev = None; prev_m = None
apps_open = None; app_open = None; app_close = None; lo_val = None
for m in tok.finditer(text):
    if m.group(2) == '{':
        stack.append((prev or '').lower())
        if stack == want: apps_open = m.end()
        if stack == want + [appid]: app_open = m.end()
        prev = None
    elif m.group(2) == '}':
        if stack == want + [appid] and app_close is None: app_close = m.start()
        if stack: stack.pop()
        prev = None
    elif m.group(1) is not None:
        s = m.group(1)
        if prev is not None and stack == want + [appid] and prev.lower() == 'launchoptions':
            lo_val = (m.start(), m.end(), s)
            prev = None
        else:
            prev = s; prev_m = m
def esc(v): return v.replace('\\', '\\\\').replace('"', '\\"')
def unesc(v): return v.replace('\\"', '"').replace('\\\\', '\\')
if lo_val:
    old = unesc(lo_val[2]).strip()
    if 'winmm' in old and 'WINEDLLOVERRIDES' in old and '%command%' in old:
        print('already set'); sys.exit(0)
    # keep whatever else was there
    rest = re.sub(r'WINEDLLOVERRIDES=("[^"]*"|\S+)\s*', '', old)
    if '%command%' in rest:
        merged = new.replace(' %command%', '') + ' ' + rest
    else:
        merged = new + (' ' + rest if rest else '')
    text = text[:lo_val[0]] + '"' + esc(merged) + '"' + text[lo_val[1]:]
elif app_open is not None:
    nl = text.find('\n', app_open)
    indent = re.match(r'[ \t]*', text[nl+1:]).group(0) or '\t'
    text = text[:nl+1] + indent + '"LaunchOptions"\t\t"' + esc(new) + '"\n' + text[nl+1:]
elif apps_open is not None:
    nl = text.find('\n', apps_open)
    indent = re.match(r'[ \t]*', text[nl+1:]).group(0) or '\t'
    block = (indent + '"' + appid + '"\n' + indent + '{\n' + indent + '\t"LaunchOptions"\t\t"' + esc(new) + '"\n' + indent + '}\n')
    text = text[:nl+1] + block + text[nl+1:]
else:
    print('no apps section in this file'); sys.exit(2)
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(text)
print('written')
PY
    done
}

# ------------------------------------------------------- release picking ----
NC_VER=""; NC_URL=""; NC_SHA=""; NC_GAMES=""; NC_PROTO=""; NC_R4=""; NC_BUILD=""; NC_SHA_OK=0
fetch_release() {   # fills NC_* with the site's latest build for this game version; 1 when offline
    local json="$1"
    curl -fsSL --connect-timeout 20 -o "$json" "$NIGHTCOOP_SITE/releases.json" || return 1
    read -r NC_VER NC_URL NC_SHA NC_GAMES NC_PROTO NC_R4 NC_BUILD < <(python3 -I - "$json" "${GAME_VER:-}" "$NIGHTCOOP_SITE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); gv = sys.argv[2]; site = sys.argv[3]
rels = [r for r in d.get('releases', []) if not r.get('yanked')]
def short(v):  # "2.5" matches "2.50"
    return v.rstrip('0').rstrip('.') if '.' in v else v
match = [r for r in rels if gv and any(short(g) == short(gv) for g in r.get('game', []))]
pick = (match or rels or [None])[0]
if not pick: print("none - - - - - -"); sys.exit(0)
# newer releases ship one archive per game version (each file lists its own "game");
# older ones ship a single archive with no "game" key
mods = [x for x in pick.get('files', []) if x.get('kind') == 'mod']
f = next((x for x in mods if gv and any(short(g) == short(gv) for g in x.get('game', []))), None) \
    or next((x for x in mods if not x.get('game')), None) or (mods[0] if mods else None)
url = f['url'] if f else '-'
if url != '-' and not url.startswith('http'): url = site.rstrip('/') + '/' + url.lstrip('/')
games = ",".join((f or {}).get('game') or pick.get('game', [])) or "-"
print(pick["version"], url, (f or {}).get("sha256", "-"), games, pick.get("protocol", "-"), (f or {}).get("red4ext", "-"), pick.get("build", "-"))
PY
)
    [ "$NC_VER" = none ] && NC_VER=""
    return 0
}

installed_version() {   # version of the NightCoop this script installed; empty if unknown or not installed
    [ -f "$NC_DLL" ] && [ -f "$STATE_FILE" ] || return 0
    local sha; sha="$(sha256sum "$NC_DLL" | cut -d' ' -f1)"
    grep -q "^dll_sha256=$sha\$" "$STATE_FILE" && sed -n 's/^version=//p' "$STATE_FILE" | head -1 || true
}

write_state() {   # version protocol build
    [ -f "$NC_DLL" ] || return 0
    { echo "version=$1"; echo "protocol=$2"; echo "build=$3"
      echo "dll_sha256=$(sha256sum "$NC_DLL" | cut -d' ' -f1)"; echo "installed=$(date -Is)"
      echo "# written by nightcoop-bazzite-install.sh; used to tell whether an update is needed"; } > "$STATE_FILE"
}

nc_up_to_date() {   # 0 when the installed NightCoop is the site's latest for this game version
    [ -n "$NC_VER" ] || return 1
    local inst; inst="$(installed_version)"
    [ -n "$inst" ] && [ "$inst" = "$NC_VER" ]
}

print_manual_launch_options() {
    bold "One manual step left"
    cat <<EOF
  In Steam: right-click Cyberpunk 2077 > Properties > General > Launch Options, paste exactly:

      $LAUNCH_OPTS

  Without it Proton ignores RED4ext's loader and the mod never starts.
EOF
    echo
}

# ------------------------------------------------------------------ check ----
do_check() {
    bold "Current state"
    local rv lv nc r4
    r4="$(red4ext_version)"; rv="$(runtime_version)"
    [ -n "$r4" ] && info "RED4ext.dll:          $r4 $(ver_ge "$r4" "$RED4EXT_VER" && echo '(ok)' || echo "(needs $RED4EXT_VER)")" || info "RED4ext.dll:          not installed"
    nc="$GAME_DIR/red4ext/plugins/NightCoop/NightCoop.dll"
    local inst; inst="$(installed_version)"
    [ -f "$nc" ] && info "NightCoop.dll:        ${inst:-unknown build (not installed by this script)} ($(stat -c %s "$nc") bytes, $(date -r "$nc" +%F))" || info "NightCoop.dll:        not installed"
    [ -f "$GAME_DIR/bin/x64/winmm.dll" ] && info "loader winmm.dll:     present" || info "loader winmm.dll:     missing"
    [ -n "$rv" ] && info "prefix C++ runtime:   $rv $(ver_ge "$rv" "$MIN_RUNTIME" && echo '(ok)' || echo "(too old, needs >= $MIN_RUNTIME)")" || info "prefix C++ runtime:   msvcp140.dll missing"
    lv="$(launch_options_status)"
    case "$lv" in
        ok) info "Steam launch options: set" ;;
        missing) info "Steam launch options: MISSING, set to: $LAUNCH_OPTS" ;;
        *) info "Steam launch options: could not read Steam's user config" ;;
    esac
    local mm; mm="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
    [ "$mm" -ge 1048576 ] 2>/dev/null && info "vm.max_map_count:     $mm" || warn "vm.max_map_count is $mm; Cyberpunk wants 1048576 or more (Bazzite sets this by default)"
    local log; log="$(ls -t "$GAME_DIR"/red4ext/logs/*.log 2>/dev/null | head -1 || true)"
    if [ -n "$log" ]; then
        info "latest RED4ext log:   $(basename "$log")"
        grep -E 'is initializing|Product version|plugin\(s\) loaded|has been loaded|\[error|\[critical' "$log" | sed 's/^/      /' | head -8
        [ -s "$log" ] || warn "the log is empty: RED4ext crashed before it could write (the error 998 symptom)"
    else
        info "latest RED4ext log:   none yet (game not launched since install)"
    fi
    local nlog; nlog="$(ls -t "$GAME_DIR"/red4ext/plugins/NightCoop/logs/*.log 2>/dev/null | head -1 || true)"
    [ -n "$nlog" ] && info "latest NightCoop log: $(basename "$nlog")"
    local tj; tj="$(mktemp)"
    if fetch_release "$tj"; then
        if [ -n "$NC_VER" ]; then
            info "latest on the site:   $NC_VER (protocol $NC_PROTO, for game $NC_GAMES)"
            if [ ! -f "$nc" ]; then info "status:               not installed; run '$0' to install"
            elif nc_up_to_date; then ok "NightCoop is up to date"
            else warn "update available: run '$0' to update ${inst:+from $inst }to $NC_VER"; fi
        fi
    else
        info "latest on the site:   unknown (could not reach $NIGHTCOOP_SITE)"
    fi
    rm -f "$tj"
}

# ---------------------------------------------------------------- restore ----
do_restore() {
    [ -d "$RESTORE_DIR" ] || fail "no such backup directory: $RESTORE_DIR"
    game_running && fail "quit the game first"
    bold "Restoring from $RESTORE_DIR"
    if [ -d "$RESTORE_DIR/game" ]; then
        if [ -f "$RESTORE_DIR/game/bin/x64/winmm.dll" ]; then cp -a "$RESTORE_DIR/game/bin/x64/winmm.dll" "$GAME_DIR/bin/x64/winmm.dll"; else rm -f "$GAME_DIR/bin/x64/winmm.dll"; fi
        rm -rf "$GAME_DIR/red4ext"
        [ -d "$RESTORE_DIR/game/red4ext" ] && cp -a "$RESTORE_DIR/game/red4ext" "$GAME_DIR/red4ext"
        ok "game folder files restored"
    fi
    if [ -d "$RESTORE_DIR/prefix-runtime" ]; then
        cp -a "$RESTORE_DIR/prefix-runtime/." "$SYS32/"
        ok "prefix runtime DLLs restored ($(runtime_version))"
    fi
    info "Launch options were not changed; remove them in Steam by hand if you want."
}

# ---------------------------------------------------------------- install ----
do_install() {
    game_running && fail "Cyberpunk 2077 is running. Quit it and run this again."

    TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:-}"' EXIT
    local STAMP; STAMP="$(date +%Y-%m-%d-%H%M%S)"
    local BACKUP="$HOME/nightcoop-backup-$STAMP"

    # ---- pick the NightCoop build
    bold "NightCoop build"
    if [ -n "$NIGHTCOOP_ZIP" ]; then
        [ -f "$NIGHTCOOP_ZIP" ] || fail "no such file: $NIGHTCOOP_ZIP"
        ok "using local archive $NIGHTCOOP_ZIP"
    fi
    if fetch_release "$TMP/releases.json"; then
        if [ -z "$NC_VER" ]; then
            warn "the site lists no builds; you need --nightcoop-zip"
        else
            ok "latest build for this game version: $NC_VER (for game $NC_GAMES, protocol $NC_PROTO, bundles RED4ext ${NC_R4})"
            case ",$NC_GAMES," in *",${GAME_VER%.0},"*|*",$GAME_VER,"*) ;; *) warn "build $NC_VER does not list game version '$GAME_VER' as supported; it may refuse to load";; esac
        fi
    else
        warn "could not reach $NIGHTCOOP_SITE; working offline"
    fi
    local NEED_NC=1 UPDATE=0 INSTALLED; INSTALLED="$(installed_version)"
    if [ -f "$NC_DLL" ]; then
        if [ -z "$NIGHTCOOP_ZIP" ] && [ "$FORCE" = 0 ] && nc_up_to_date; then
            ok "installed: $INSTALLED, already the latest; the mod files stay as they are (--force reinstalls them)"
            NEED_NC=0
        else
            UPDATE=1
            if [ "$FORCE" = 1 ] && [ -n "$INSTALLED" ] && [ "$INSTALLED" = "$NC_VER" ]; then info "installed: $INSTALLED; --force: the mod files will be reinstalled"
            else info "installed: ${INSTALLED:-unknown build (not installed by this script)}; will be replaced with ${NIGHTCOOP_ZIP:+the given archive}${NIGHTCOOP_ZIP:-$NC_VER}"; fi
        fi
    fi
    if [ "$NEED_NC" = 1 ] && [ -z "$NIGHTCOOP_ZIP" ]; then
        [ -n "${NC_URL:-}" ] && [ "$NC_URL" != "-" ] || fail "no download URL available; download the archive from $NIGHTCOOP_SITE/download.html and pass --nightcoop-zip"
        NIGHTCOOP_ZIP="$TMP/$(basename "$NC_URL")"
        [ "$DRY_RUN" = 1 ] && info "(dry run) would download $NC_URL" || download "$NC_URL" "$NIGHTCOOP_ZIP"
    fi
    if [ -f "$NIGHTCOOP_ZIP" ] && [ -n "${NC_SHA:-}" ] && [ "$NC_SHA" != "-" ]; then
        if sha_check "$NIGHTCOOP_ZIP" "$NC_SHA"; then ok "NightCoop archive SHA-256 matches the site's releases.json"; NC_SHA_OK=1
        else
            if [ -n "$NC_VER" ] && [[ "$(basename "$NIGHTCOOP_ZIP")" == *"$NC_VER"* ]]; then fail "SHA-256 mismatch for $NIGHTCOOP_ZIP"; else warn "local archive is a different build than the site's latest ($NC_VER); hash not compared"; fi
        fi
    fi
    # a NightCoop that was put in by hand: if its DLL is byte-for-byte the one in the archive, just record it
    if [ "$NEED_NC" = 1 ] && [ -z "$INSTALLED" ] && [ -f "$NC_DLL" ] && [ "$FORCE" = 0 ] && [ "$NC_SHA_OK" = 1 ] && [ -f "$NIGHTCOOP_ZIP" ]; then
        rm -rf "$TMP/nc"; mkdir -p "$TMP/nc"; unzip -q -o "$NIGHTCOOP_ZIP" -d "$TMP/nc"
        local ZDLL; ZDLL="$(find "$TMP/nc" -type f -iname NightCoop.dll -path '*red4ext/plugins/NightCoop/*' | head -1)"
        if [ -n "$ZDLL" ] && [ "$(sha256sum "$ZDLL" | cut -d' ' -f1)" = "$(sha256sum "$NC_DLL" | cut -d' ' -f1)" ]; then
            write_state "$NC_VER" "$NC_PROTO" "$NC_BUILD"; INSTALLED="$NC_VER"
            ok "the NightCoop.dll already in the game folder is $NC_VER; recorded, nothing to replace"
            NEED_NC=0; UPDATE=0
        fi
    fi
    [ -n "$SAVE_BACKUP" ] || { [ "$UPDATE" = 1 ] && SAVE_BACKUP=0 || SAVE_BACKUP=1; }

    # ---- RED4ext
    bold "RED4ext $RED4EXT_VER"
    local NEED_R4=1 R4NOW; R4NOW="$(red4ext_version)"
    if [ "$NEED_NC" = 0 ] && [ -n "$R4NOW" ] && ver_ge "$R4NOW" "$RED4EXT_VER"; then
        ok "already $R4NOW"; NEED_R4=0
    else
        if [ -z "$RED4EXT_ZIP" ]; then
            RED4EXT_ZIP="$TMP/red4ext-${RED4EXT_VER}.zip"
            [ "$DRY_RUN" = 1 ] && info "(dry run) would download $RED4EXT_URL" || download "$RED4EXT_URL" "$RED4EXT_ZIP"
        fi
        if [ -f "$RED4EXT_ZIP" ]; then
            sha_check "$RED4EXT_ZIP" "$RED4EXT_SHA" && ok "red4ext zip SHA-256 verified" || fail "SHA-256 mismatch for $RED4EXT_ZIP (expected $RED4EXT_SHA)"
        fi
    fi

    # ---- C++ runtime
    bold "Visual C++ runtime in the Proton prefix"
    local RV NEED_RT=0; RV="$(runtime_version)"
    if [ -n "$RV" ] && ver_ge "$RV" "$MIN_RUNTIME"; then ok "already $RV"; else
        NEED_RT=1; info "prefix has ${RV:-none}; needs >= $MIN_RUNTIME"
        if [ -z "$VCREDIST" ]; then
            local lib c
            for lib in "${LIBS[@]}"; do
                c="$lib/steamapps/common/Steamworks Shared/_CommonRedist/vcredist/2022/VC_redist.x64.exe"
                if [ -f "$c" ] && ver_ge "$(pe_version "$c" file)" "$MIN_RUNTIME"; then VCREDIST="$c"; break; fi
            done
        fi
        if [ -n "$VCREDIST" ]; then ok "installer: $VCREDIST ($(pe_version "$VCREDIST" file))"
        else
            VCREDIST="$TMP/VC_redist.x64.exe"
            if [ "$DRY_RUN" = 1 ]; then info "(dry run) would download $VCREDIST_URL"; else
                download "$VCREDIST_URL" "$VCREDIST"
                [ "$(stat -c %s "$VCREDIST")" -gt 10000000 ] && head -c 2 "$VCREDIST" | grep -q 'MZ' || fail "the downloaded VC_redist.x64.exe does not look like the installer"
                ok "installer: $(pe_version "$VCREDIST" file) from Microsoft"
            fi
        fi
    fi

    # ---- launch options
    bold "Steam launch options"
    local LO; LO="$(launch_options_status)"
    case "$LO" in
        ok) ok "already contain the winmm override" ;;
        missing) steam_running && warn "not set; Steam is running so the script cannot write them (see the end)" || info "not set; will be written to Steam's config" ;;
        *) warn "could not find Steam's per-user config; set the launch options by hand (see the end)" ;;
    esac

    # ---- nothing to do?
    if [ "$NEED_NC" = 0 ] && [ "$NEED_R4" = 0 ] && [ "$NEED_RT" = 0 ]; then
        echo
        if [ "$LO" = missing ] && ! steam_running && [ "$DRY_RUN" = 0 ]; then
            bold "Writing launch options"
            set_launch_options
            LO="$(launch_options_status)"
            [ "$LO" = ok ] && ok "launch options set" || warn "could not set them automatically"
        fi
        if [ "$LO" = ok ]; then ok "everything is up to date; nothing to do"
        else warn "the mod files are current, but the launch options are not set"; echo; print_manual_launch_options; fi
        return 0
    fi

    # ---- plan
    echo
    bold "Plan"
    [ "$UPDATE" = 1 ] && info "update        NightCoop ${INSTALLED:-unknown build} -> ${NC_VER:-$(basename "$NIGHTCOOP_ZIP")}"
    if [ "$SAVE_BACKUP" = 1 ] && [ -d "$SAVES" ]; then info "backup saves  -> $BACKUP/Saved Games ($(du -sh "$SAVES" 2>/dev/null | cut -f1))"
    elif [ "$UPDATE" = 1 ] && [ -d "$SAVES" ]; then info "backup saves  skipped on an update (add --backup-saves to copy them)"; fi
    info "backup files  -> $BACKUP/game and $BACKUP/prefix-runtime"
    [ "$NEED_NC" = 1 ] && info "install       NightCoop $(basename "$NIGHTCOOP_ZIP") into the game folder"
    [ "$NEED_R4" = 1 ] && info "overlay       RED4ext $RED4EXT_VER (replaces whatever the archive bundles)"
    [ "$NEED_RT" = 1 ] && info "run           VC_redist.x64.exe quietly inside the game's Proton prefix"
    [ "$LO" = missing ] && ! steam_running && info "write         launch options: $LAUNCH_OPTS"
    [ "$DRY_RUN" = 1 ] && { echo; ok "dry run finished, nothing changed"; return 0; }
    echo
    confirm "Go ahead?" || { info "aborted"; exit 1; }

    # ---- backups
    bold "Backing up"
    mkdir -p "$BACKUP/game/bin/x64" "$BACKUP/prefix-runtime"
    if [ "$SAVE_BACKUP" = 1 ] && [ -d "$SAVES" ]; then
        cp -a "$SAVES" "$BACKUP/Saved Games"; ok "saves copied ($(ls -1 "$BACKUP/Saved Games" | wc -l) slots)"
    fi
    [ -f "$GAME_DIR/bin/x64/winmm.dll" ] && cp -a "$GAME_DIR/bin/x64/winmm.dll" "$BACKUP/game/bin/x64/"
    [ -d "$GAME_DIR/red4ext" ] && cp -a "$GAME_DIR/red4ext" "$BACKUP/game/red4ext"
    cp -a "$SYS32"/msvcp140*.dll "$SYS32"/vcruntime140*.dll "$SYS32"/concrt140.dll "$SYS32"/vccorlib140.dll "$BACKUP/prefix-runtime/" 2>/dev/null || true
    ok "backup folder: $BACKUP"

    # ---- NightCoop files
    if [ "$NEED_NC" = 1 ]; then
        bold "Installing NightCoop"
        rm -rf "$TMP/nc"; mkdir -p "$TMP/nc"; unzip -q -o "$NIGHTCOOP_ZIP" -d "$TMP/nc"
        local ROOT; ROOT="$(dirname "$(dirname "$(dirname "$(dirname "$(find "$TMP/nc" -type f -iname NightCoop.dll -path '*red4ext/plugins/NightCoop/*' | head -1)")")")")"
        [ -f "$ROOT/red4ext/plugins/NightCoop/NightCoop.dll" ] || fail "the archive does not contain red4ext/plugins/NightCoop/NightCoop.dll"
        cp -a "$ROOT/." "$GAME_DIR/"
        # remember what was installed, so the next run can tell whether an update is needed
        local SVER="$NC_VER"
        if [ "$NC_SHA_OK" != 1 ]; then   # a local archive the site did not vouch for: name it after the file
            SVER="$(basename "$NIGHTCOOP_ZIP" | sed -E 's/^NightCoop-//; s/\.zip$//; s/-[0-9]+\.[0-9]+$//')"
            [ -n "$SVER" ] || SVER="local"
        fi
        write_state "$SVER" "${NC_PROTO:--}" "${NC_BUILD:--}"
        ok "NightCoop $SVER in place ($(date -r "$NC_DLL" +%F))"
    fi

    # ---- RED4ext overlay
    if [ "$NEED_R4" = 1 ]; then
        bold "Installing RED4ext $RED4EXT_VER"
        rm -rf "$TMP/r4"; mkdir -p "$TMP/r4"; unzip -q -o "$RED4EXT_ZIP" -d "$TMP/r4"
        [ -f "$TMP/r4/red4ext/RED4ext.dll" ] && [ -f "$TMP/r4/bin/x64/winmm.dll" ] || fail "unexpected red4ext zip layout"
        cp -a "$TMP/r4/." "$GAME_DIR/"
        local R4; R4="$(red4ext_version)"
        ver_ge "$R4" "$RED4EXT_VER" && ok "RED4ext.dll is $R4" || fail "RED4ext.dll reports $R4 after install"
    fi

    # ---- runtime
    if [ "$NEED_RT" = 1 ]; then
        bold "Installing the C++ runtime into the prefix"
        info "this runs the Microsoft installer under Proton; it takes about a minute"
        ( export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" STEAM_COMPAT_DATA_PATH="$COMPAT" SteamAppId="$APPID" SteamGameId="$APPID"
          timeout 600 "$PROTON_DIR/proton" run "$VCREDIST" /install /quiet /norestart ) > "$TMP/vcredist.log" 2>&1 || warn "installer exit code $? (3010 just means 'reboot requested' on Windows and is fine)"
        RV="$(runtime_version)"
        if ver_ge "$RV" "$MIN_RUNTIME"; then ok "prefix runtime is now $RV"; else
            warn "runtime is still ${RV:-missing}. Fallback: protontricks $APPID --force vcrun2022  (then rerun '$0 check')"
        fi
    fi

    # ---- launch options
    if [ "$LO" = missing ] && ! steam_running; then
        bold "Writing launch options"
        set_launch_options
        [ "$(launch_options_status)" = ok ] && ok "launch options set" || warn "could not set them automatically; set by hand (see below)"
        LO="$(launch_options_status)"
    fi

    # ---- done
    echo
    bold "Done"
    do_check
    echo
    [ "$LO" != ok ] && print_manual_launch_options
    cat <<EOF
  Now launch Cyberpunk 2077 from Steam. In the main menu a Co-op entry
  ("Совместная игра" / "Co-op") should appear. If it does not, run:

      $0 check

  Backups of everything replaced are in: $BACKUP
  To undo:  $0 restore "$BACKUP"
EOF
}

case "$MODE" in
    check)   do_check ;;
    restore) do_restore ;;
    install) do_install ;;
esac
