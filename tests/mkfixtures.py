#!/usr/bin/env python3
"""Fixtures for run-tests.sh: synthetic PE files, archives, a fake Steam tree and Proton.

    mkfixtures.py archives DIR            NightCoop/RED4ext archives, installers, releases.json
    mkfixtures.py world DIR FIX LAYOUT [OPTS]  a home folder with Steam, the game and a Proton prefix

LAYOUT is one of: native (game on a second library, as on a Steam Deck SD card),
flatpak (Flatpak Steam, sandbox paths in Steam's files) or cachyos (both proton-cachyos
packages installed, Steam's default set to Proton 10, no config_info yet). OPTS: see world().
"""
import hashlib
import json
import os
import struct
import sys
import zipfile


# ------------------------------------------------------------------ PE files
def _block(key, value=b'', typ=0, children=b''):
    k = key.encode('utf-16le') + b'\0\0'
    body = k + b'\0' * ((4 - (6 + len(k)) % 4) % 4) + value
    if children:
        body += b'\0' * ((4 - (6 + len(body)) % 4) % 4) + children
    vlen = len(value) // 2 if typ == 1 else len(value)
    return struct.pack('<HHH', 6 + len(body), vlen, typ) + body


def _pad4(b):
    return b + b'\0' * ((4 - len(b) % 4) % 4)


def _ver(v):
    p = [int(x) for x in v.split('.')] + [0, 0, 0, 0]
    return (p[0] << 16) | p[1], (p[2] << 16) | p[3]


def version_info(file_ver, product_ver, strings):
    fms, fls = _ver(file_ver)
    pms, pls = _ver(product_ver)
    fixed = struct.pack('<13I', 0xFEEF04BD, 0x10000, fms, fls, pms, pls, 0x3f, 0, 0x40004, 2, 0, 0, 0)
    table = b''.join(_pad4(_block(k, (v + '\0').encode('utf-16le'), 1)) for k, v in strings.items())
    sfi = _block('StringFileInfo', typ=1, children=_pad4(_block('040904B0', typ=1, children=table)))
    vfi = _block('VarFileInfo', typ=1, children=_block('Translation', struct.pack('<HH', 0x409, 1200)))
    return _block('VS_VERSION_INFO', fixed, 0, _pad4(sfi) + vfi)


def make_pe(path, file_ver='1.0.0.0', product_ver=None, linker=(14, 0), imports=(), strings=None, pad=0,
            fixed_product=None):
    product_ver = product_ver or file_ver
    s = {'FileVersion': file_ver, 'ProductVersion': product_ver}
    s.update(strings or {})
    vi = version_info(file_ver, fixed_product or (product_ver.split(' ')[0] if product_ver[0].isdigit() else file_ver), s)

    idata = bytearray()
    names = b''
    desc_size = 20 * (len(imports) + 1)
    for i, name in enumerate(imports):
        idata += struct.pack('<5I', 0, 0, 0, 0x1000 + desc_size + len(names), 0)
        names += name.encode() + b'\0'
    idata += b'\0' * 20 + names
    idata = bytes(idata).ljust(0x200, b'\0')

    rsrc = bytearray()
    rsrc += struct.pack('<IIHHHH', 0, 0, 0, 0, 0, 1) + struct.pack('<II', 16, 0x80000000 | 24)
    rsrc += struct.pack('<IIHHHH', 0, 0, 0, 0, 0, 1) + struct.pack('<II', 1, 0x80000000 | 48)
    rsrc += struct.pack('<IIHHHH', 0, 0, 0, 0, 0, 1) + struct.pack('<II', 0x409, 72)
    rsrc += struct.pack('<IIII', 0x2000 + 88, len(vi), 0, 0)
    rsrc += vi
    rsrc = bytes(rsrc)
    rsrc_raw = rsrc.ljust((len(rsrc) + 0x1ff) & ~0x1ff, b'\0')

    opt = bytearray(240)
    struct.pack_into('<HBB', opt, 0, 0x20b, linker[0], linker[1])
    struct.pack_into('<Q', opt, 24, 0x180000000)
    struct.pack_into('<II', opt, 32, 0x1000, 0x200)
    struct.pack_into('<II', opt, 56, 0x2000 + ((len(rsrc) + 0xfff) & ~0xfff), 0x400)
    struct.pack_into('<HH', opt, 68, 2, 0x160)
    struct.pack_into('<I', opt, 108, 16)
    struct.pack_into('<II', opt, 112 + 8, 0x1000, desc_size)       # import table
    struct.pack_into('<II', opt, 112 + 16, 0x2000, len(rsrc))      # resources
    coff = struct.pack('<HHIIIHH', 0x8664, 2, 0, 0, 0, 240, 0x2022)
    secs = struct.pack('<8sIIIIIIHHI', b'.idata', 0x200, 0x1000, 0x200, 0x400, 0, 0, 0, 0, 0xC0000040)
    secs += struct.pack('<8sIIIIIIHHI', b'.rsrc', len(rsrc), 0x2000, len(rsrc_raw), 0x600, 0, 0, 0, 0, 0x40000040)
    dos = bytearray(64)
    dos[0:2] = b'MZ'
    struct.pack_into('<I', dos, 0x3c, 0x40)
    head = bytes(dos) + b'PE\0\0' + coff + bytes(opt) + secs
    data = head.ljust(0x400, b'\0') + idata + rsrc_raw + b'\0' * pad
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data)


CRT = ('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll', 'KERNEL32.dll')


def sha(path):
    with open(path, 'rb') as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def write(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(text)
    if mode:
        os.chmod(path, mode)


def zipdir(zpath, files):
    """files: {archive name: source path or bytes}"""
    os.makedirs(os.path.dirname(zpath), exist_ok=True)
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, src in files.items():
            if isinstance(src, bytes):
                z.writestr(name, src)
            else:
                z.write(src, name)


# ------------------------------------------------------------------ archives
GAME = {   # patch: (Cyberpunk2077.exe file version, fixed product version), as the real builds have them
    '2.5': ('3.0.88.46235', '2.5.0.0'),
    '2.31': ('3.0.80.51928', '2.3.1.0'),
}


def archives(fix):
    pe = os.path.join(fix, 'pe')
    make_pe(f'{pe}/nc1/NightCoop.dll', '0.2.0.0', linker=(14, 51), imports=CRT)
    make_pe(f'{pe}/nc1/legacy.dll', '0.2.0.0', linker=(14, 44), imports=CRT)
    make_pe(f'{pe}/nc2/NightCoop.dll', '0.2.1.0', linker=(14, 51), imports=CRT)
    make_pe(f'{pe}/nc0/NightCoop.dll', '0.1.1.0', linker=(14, 44), imports=CRT)
    for name, ver, lk in (('r4old', '1.30.0', (14, 44)), ('r4new', '1.31.0', (14, 51)), ('r4next', '1.32.0', (14, 51))):
        make_pe(f'{pe}/{name}/RED4ext.dll', ver + '.0', ver, linker=lk, imports=CRT)
        make_pe(f'{pe}/{name}/winmm.dll', ver + '.0', ver, linker=lk, imports=CRT)
    desc = {'FileDescription': 'Microsoft Visual C++ v14 Redistributable (x64) - 14.51.36247',
            'ProductName': 'Microsoft Visual C++ v14 Redistributable (x64) - 14.51.36247'}
    make_pe(f'{fix}/site/vc_redist.x64.exe', '14.51.36247.0', strings=desc, pad=4096)
    make_pe(f'{fix}/pe/new-msvcp140.dll', '14.51.36247.0', strings={'FileDescription': 'Microsoft C Runtime Library'})
    make_pe(f'{fix}/pe/old-msvcp140.dll', '14.29.30157.0', strings={'FileDescription': 'Microsoft C Runtime Library'})
    make_pe(f'{fix}/pe/steamworks-vc_redist.x64.exe', '14.44.35211.0', pad=4096, strings={
        'FileDescription': 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.44.35211'})
    make_pe(f'{fix}/pe/other.dll', '2.0.0.0', linker=(14, 30), imports=CRT)
    make_pe(f'{fix}/pe/cet-version.dll', '1.36.0.0', linker=(14, 44), imports=CRT)
    for patch, (fv, fp) in GAME.items():
        make_pe(f'{fix}/pe/Cyberpunk2077-{patch}.exe', fv, patch, fixed_product=fp,
                strings={'ProductName': 'Cyberpunk 2077'})

    def nightcoop(r4, nc=f'{pe}/nc1', extra=True, prefix=''):
        files = {
            prefix + 'bin/x64/winmm.dll': f'{pe}/{r4}/winmm.dll',
            prefix + 'red4ext/RED4ext.dll': f'{pe}/{r4}/RED4ext.dll',
            prefix + 'red4ext/LICENSE.txt': b'MIT\r\n',
            prefix + 'red4ext/plugins/NightCoop/NightCoop.dll': f'{nc}/NightCoop.dll',
            prefix + 'red4ext/plugins/NightCoop/redscript/NightCoopSdk.reds': b'// sdk\n',
            prefix + 'r6/scripts/NightCoopFlight/NightCoopFlight.reds': b'// flight\n',
        }
        if extra:
            files[prefix + 'red4ext/plugins/NightCoop/legacy.dll'] = f'{nc}/legacy.dll'
            files[prefix + 'archive/pc/mod/NightCoop.archive'] = b'RDAR' + b'\0' * 60
        return files

    # the live layout since 0.1.2: one archive per game patch, files at the archive root
    zipdir(f'{fix}/site/dl/0.2.0-beta/NightCoop-0.2.0-beta-2.5.zip', nightcoop('r4new'))
    zipdir(f'{fix}/site/dl/0.2.0-beta/NightCoop-0.2.0-beta-2.31.zip', nightcoop('r4old'))
    # the old single archive (0.1.1 and earlier) bundled RED4ext 1.30 for every patch
    zipdir(f'{fix}/site/dl/0.1.1-beta.2/NightCoop-0.1.1-beta.2.zip',
           dict(nightcoop('r4old', f'{pe}/nc0', extra=False, prefix='NightCoop-0.1.1-beta.2/'),
                **{'NightCoop-0.1.1-beta.2/README.txt': b'Read me\r\n'}))
    # a later build that is not on the site: legacy.dll and the .archive are gone, RED4ext 1.32 is bundled
    zipdir(f'{fix}/NightCoop-0.2.1-test.zip', {
        'red4ext\\plugins\\NightCoop\\NightCoop.dll': f'{pe}/nc2/NightCoop.dll',   # Windows-style separators
        'red4ext/plugins/NightCoop/redscript/NightCoopSdk.reds': b'// sdk\n',
        'r6/scripts/NightCoopFlight/NightCoopFlight.reds': b'// flight\n',
        'red4ext/RED4ext.dll': f'{pe}/r4next/RED4ext.dll',
        'bin/x64/winmm.dll': f'{pe}/r4next/winmm.dll',
    })
    zipdir(f'{fix}/red4ext-1.31.0.zip', {
        'bin/x64/winmm.dll': f'{pe}/r4new/winmm.dll',
        'red4ext/RED4ext.dll': f'{pe}/r4new/RED4ext.dll',
        'red4ext/LICENSE.txt': b'MIT\r\n',
        'red4ext/THIRD_PARTY_LICENSES.txt': b'...\r\n',
    })
    zipdir(f'{fix}/evil.zip', {'../../escape.txt': b'x'})

    def entry(rel, games=None, red4ext=None, kind='mod'):
        e = {'kind': kind, 'name': os.path.basename(rel), 'url': rel, 'sha256': sha(f'{fix}/site/{rel}')}
        if games:
            e['game'] = games
        if red4ext:
            e['red4ext'] = red4ext
        return e

    rel = {'schema': 1, 'latest': '0.2.0-beta', 'releases': [   # the shape of nightcoop.net/releases.json
        {'version': '0.2.0-beta', 'channel': 'beta', 'game': ['2.5', '2.31'], 'protocol': 164, 'yanked': None,
         'files': [entry('dl/0.2.0-beta/NightCoop-0.2.0-beta-2.5.zip', ['2.5'], '1.31.0'),
                   entry('dl/0.2.0-beta/NightCoop-0.2.0-beta-2.31.zip', ['2.31'], '1.30.0'),
                   {'kind': 'source', 'url': 'dl/src.zip'}]},
        {'version': '0.1.1-beta.2', 'channel': 'beta', 'game': ['2.5', '2.31'], 'protocol': 128, 'yanked': None,
         'files': [entry('dl/0.1.1-beta.2/NightCoop-0.1.1-beta.2.zip')]},
        {'version': '0.1.0-beta.1', 'channel': 'beta', 'game': ['2.5'], 'protocol': 120, 'yanked': True,
         'files': [{'kind': 'mod', 'url': 'dl/0.1.0-beta.1/NightCoop-0.1.0-beta.1.zip', 'sha256': '2' * 64}]},
    ]}
    write(f'{fix}/site/releases.json', json.dumps(rel, indent=1))
    write(f'{fix}/red4ext.sha256', sha(f'{fix}/red4ext-1.31.0.zip'))


# --------------------------------------------------------------------- world
VDF_LOCALCONFIG = '''"UserLocalConfigStore"
{
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"apps"
\t\t\t\t{
\t\t\t\t\t"1091500"
\t\t\t\t\t{
\t\t\t\t\t\t"LastPlayed"\t\t"1730000000"
\t\t\t\t\t\t"LaunchOptions"\t\t"game-performance %command% --launcher-skip"
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t}
\t}
}
'''

USER_REG = '''WINE REGISTRY Version 2
;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

#arch=win64

[Software\\\\Wine\\\\FileOpenAssociations] 1730000000
#time=1db2a1b2c3d4e5f
"Enable"="N"

'''

FAKE_PROTON = '''#!/usr/bin/env bash
# fake proton: "runinprefix VC_redist.x64.exe ..." drops a newer msvcp140.dll into the prefix
here="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$STEAM_COMPAT_DATA_PATH/fake-proton.log"
case "$1" in "run"|"runinprefix") ;; *) exit 1 ;; esac
case "$(basename "$2")" in
    [Vv][Cc]_redist*) cp "$here/new-msvcp140.dll" "$STEAM_COMPAT_DATA_PATH/pfx/drive_c/windows/system32/msvcp140.dll"; exit 194 ;;
esac
'''


def make_proton(d, fix, name=None, label=None):
    write(f'{d}/proton', FAKE_PROTON, 0o755)
    write(f'{d}/version', '1730000000 proton-10.0-100\n')
    os.makedirs(f'{d}/files/share/fonts', exist_ok=True)
    with open(f'{fix}/pe/new-msvcp140.dll', 'rb') as src, open(f'{d}/new-msvcp140.dll', 'wb') as dst:
        dst.write(src.read())
    if name:   # as proton-cachyos ships it
        write(f'{d}/compatibilitytool.vdf', '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s"\n    {\n'
              '      "install_path" "."\n      "display_name" "%s"\n      "from_oslist"  "windows"\n'
              '      "to_oslist"    "linux"\n    }\n  }\n}\n' % (name, label or name))


def copy(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(src, 'rb') as a, open(dst, 'wb') as b:
        b.write(a.read())


def world(home, fix, layout, *opts):
    """opts: 2.31 (game patch 2.31), cet (Cyber Engine Tweaks present), manual (NightCoop
    copied in by hand earlier, with a file newer builds no longer ship and the user's servers.txt)."""
    home = os.path.abspath(home)
    patch = '2.31' if '2.31' in opts else '2.5'
    if layout == 'flatpak':
        steam = f'{home}/.var/app/com.valvesoftware.Steam/.local/share/Steam'
        seen_root = f'{home}/.local/share/Steam'          # how the sandbox sees it
        game_lib = steam
        libs = [seen_root]
    else:
        steam = seen_root = f'{home}/.local/share/Steam'
        game_lib = f'{home}/sdcard'
        libs = [seen_root, game_lib]
    os.makedirs(f'{steam}/steamapps', exist_ok=True)
    os.makedirs(f'{game_lib}/steamapps', exist_ok=True)
    body = ''.join('\t"%d"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"apps"\n\t\t{\n%s\t\t}\n\t}\n'
                   % (i, p, '\t\t\t"1091500"\t\t"70000000000"\n' if p == (seen_root if layout == 'flatpak' else game_lib) else '')
                   for i, p in enumerate(libs))
    write(f'{steam}/steamapps/libraryfolders.vdf', '"libraryfolders"\n{\n' + body + '}\n')
    write(f'{game_lib}/steamapps/appmanifest_1091500.acf',
          '"AppState"\n{\n\t"appid"\t\t"1091500"\n\t"installdir"\t\t"Cyberpunk 2077"\n}\n')
    game = f'{game_lib}/steamapps/common/Cyberpunk 2077'
    copy(f'{fix}/pe/Cyberpunk2077-{patch}.exe', f'{game}/bin/x64/Cyberpunk2077.exe')
    if 'cet' in opts:
        copy(f'{fix}/pe/cet-version.dll', f'{game}/bin/x64/version.dll')
    if 'manual' in opts:
        nc = f'{game}/red4ext/Plugins/NightCoop'
        copy(f'{fix}/pe/nc0/NightCoop.dll', f'{nc}/NightCoop.dll')
        copy(f'{fix}/pe/other.dll', f'{nc}/old-helper.dll')
        write(f'{nc}/servers.txt', 'hub.example.org#K3QF-9X2M\n')
        write(f'{nc}/logs/nightcoop-last-crash.log', 'crash\n')
    copy(f'{fix}/pe/other.dll', f'{game}/red4ext/Plugins/OtherMod/other.dll')   # another user's plugin, odd case
    write(f'{game}/archive/pc/content/basegame_1_engine.archive', 'RDAR')
    copy(f'{fix}/pe/steamworks-vc_redist.x64.exe',
         f'{steam}/steamapps/common/Steamworks Shared/_CommonRedist/vcredist/2022/VC_redist.x64.exe')

    compat = f'{game_lib}/steamapps/compatdata/1091500'
    pfx = f'{compat}/pfx'
    copy(f'{fix}/pe/old-msvcp140.dll', f'{pfx}/drive_c/windows/system32/msvcp140.dll')
    copy(f'{fix}/pe/old-msvcp140.dll', f'{pfx}/drive_c/windows/system32/vcruntime140.dll')
    write(f'{pfx}/user.reg', USER_REG)
    write(f'{pfx}/drive_c/users/steamuser/Saved Games/CD Projekt Red/Cyberpunk 2077/ManualSave-0/sav.dat', 'save')
    write(f'{compat}/version', '1730000000 proton-10.0-100\n')

    if layout == 'cachyos':   # both proton-cachyos packages, Steam's default set to Proton 10, nothing per game
        make_proton(f'{steam}/compatibilitytools.d/proton-cachyos-native', fix, 'proton-cachyos-native',
                    'proton-cachyos-11.0-20261015 (native)')
        make_proton(f'{steam}/compatibilitytools.d/proton-cachyos-slr', fix, 'proton-cachyos-slr',
                    'proton-cachyos-11.0-20261015 (steam linux runtime)')
        make_proton(f'{steam}/steamapps/common/Proton - Experimental', fix)
        write(f'{steam}/config/config.vdf', '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n'
              '\t\t\t{\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n\t\t\t\t\t"0"\n\t\t\t\t\t{\n'
              '\t\t\t\t\t\t"name"\t\t"proton_10"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"75"\n'
              '\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n')
    else:   # Steam's config.vdf without any compatibility tool mapping, as on a fresh SteamOS install
        make_proton(f'{steam}/steamapps/common/Proton - Experimental', fix)
        write(f'{steam}/config/config.vdf', '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n'
              '\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"\n\t\t\t}\n\t\t}\n\t}\n}\n')
        write(f'{compat}/config_info', '10.0-100\n%s/steamapps/common/Proton - Experimental/files/share/fonts/\n'
              '%s/steamapps/common/Proton - Experimental/files/share/default_pfx/\n' % (seen_root, seen_root))

    write(f'{steam}/config/loginusers.vdf', '"users"\n{\n\t"76561197960278073"\n\t{\n\t\t"AccountName"\t\t"v"\n'
          '\t\t"MostRecent"\t\t"1"\n\t}\n}\n')
    write(f'{steam}/userdata/12345/config/localconfig.vdf', VDF_LOCALCONFIG)


if __name__ == '__main__':
    if sys.argv[1] == 'archives':
        archives(sys.argv[2])
    elif sys.argv[1] == 'world':
        world(sys.argv[2], sys.argv[3], sys.argv[4], *sys.argv[5:])
    elif sys.argv[1] == 'pe':      # pe PATH FILEVER [PRODUCTVER]
        make_pe(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    else:
        sys.exit('unknown command')
