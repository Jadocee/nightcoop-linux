#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
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
import re
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
    '2.31': ('3.0.80.51928', '2.3.1.0'),   # older than the installer supports: refused
    '2.6': ('3.0.90.10000', '2.6.0.0'),     # a patch newer than its tables
}


# The third round of the mod set (cars, the clothes of The RVC00N Dumpster 3, Nola Dreamer, Veegee,
# Street Ninja and Dolly Go-Go, Impact FX, Immersive Audio Distance) and Equipment-EX: each download's
# real file name and entries, read from the archive itself (or, for a .rar or .7z, its Nexus manifest),
# with the files a rule must pass over. Contents are stand-ins (see placeholder).
ROUND3 = {
    '0 FAIRYEXE DOLLY GOGO FUR SET 37279 1 2026-11-04T19-01Z PYMIYqW21.zip': ['0_FAIRYEXE_DOLLY_GOGO_FUR_SET/Dolly Go-Go Fur - Codes.txt', '0_FAIRYEXE_DOLLY_GOGO_FUR_SET/archive/pc/mod/FAIRYEXE_DOLLY_GOGO_FUR_SET.archive', '0_FAIRYEXE_DOLLY_GOGO_FUR_SET/archive/pc/mod/fairyexe_dolly_gogo_fur_set.xl', '0_FAIRYEXE_DOLLY_GOGO_FUR_SET/r6/tweaks/fairyexe/fairyexe_dolly_gogo_fur_set.yaml'],
    'ALL IN ONE - Fifth Element Collection 27709 1.1.0 2026-10-17T10-38Z Z0ER0BBOy.zip': ['archive/pc/mod/PinkyDude_Clothes_TFEC_KorbenJacket.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_KorbenJacket.xl', 'archive/pc/mod/PinkyDude_Clothes_TFEC_KorbenTanktop.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_KorbenTanktop.xl', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooCroptop.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooCroptop.xl', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooPants.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooPants.xl', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooRuuberSuspenders.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooRuuberSuspenders.xl', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooStrapBodysuit.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooStrapBodysuit.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_KorbenJacket.yaml', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_KorbenTanktop.yaml', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_LeelooCroptop.yaml', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_LeelooPants.yaml', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_LeelooRuuberSuspenders.yaml', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_LeelooStrapBodysuit.yaml'],
    'Apollo Intensa Emozione 1.0 37233 1 2026-11-04T08-23Z k8Iw8mo5Q.zip': ['archive/pc/mod/apollo_ie.archive', 'archive/pc/mod/apollo_ie.archive.xl', 'r6/scripts/xaires_apollo_ie/apollo_ie.reds', 'r6/scripts/xaires_apollo_ie/apollo_ie_int_ui.reds', 'r6/tweaks/xaires/apollo_ie.yaml'],
    'Bunny Slippers-26996-1-0-1-1770378913.zip': ['archive/pc/mod/PinkyDude_Clothes_BunnySlippers.archive', 'archive/pc/mod/PinkyDude_Clothes_BunnySlippers.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_BunnySlippers.yaml'],
    'Chuckwalla Tight Shirt 31111 1.0.1 2026-07-25T16-48Z 5em9eoIid.zip': ['archive/pc/mod/PinkyDude_Clothes_ChuckwallaTightShirt.archive', 'archive/pc/mod/PinkyDude_Clothes_ChuckwallaTightShirt.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_ChuckwallaTightShirt.yaml'],
    'CinematicImpactFX Settings 0.8.3.3 36631 0.8.3.3 2026-11-07T10-09Z 4rpqrKQhc.zip': ['archive/pc/mod/######CinematicImpactFX_ExplosionSmoke.archive', 'archive/pc/mod/#####CinematicImpactFX_Frag.archive', 'archive/pc/mod/CinematicImpactFX.archive', 'archive/pc/mod/CinematicImpactFX_CharacterHaze.archive', 'archive/pc/mod/CinematicImpactFX_Explosions.archive', 'archive/pc/mod/CinematicImpactFX_GunSmoke.archive', 'archive/pc/mod/CinematicImpactFX_Malorian.archive', 'archive/pc/mod/CinematicImpactFX_Melee.archive', 'archive/pc/mod/CinematicImpactFX_Tech.archive', 'r6/scripts/CIFXCharacterHaze/CIFXCharacterHaze.reds', 'r6/scripts/CIFXTechImpacts/CIFXTechImpacts.reds', 'r6/scripts/CinematicImpactFX/CIFXExplosionSmoke.reds', 'r6/scripts/CinematicImpactFX/CinematicImpactFX.reds', 'r6/tweaks/CinematicImpactFX/cinematicimpactfx.yaml', 'r6/tweaks/CinematicImpactFX/tech-prototype.yaml'],
    'Cityfolk Hoodie 37493 1.0.2 2026-11-06T16-54Z Q6xF6lDTX.zip': ['archive/pc/mod/PinkyDude_Clothes_CityfolkHoodie.archive', 'archive/pc/mod/PinkyDude_Clothes_CityfolkHoodie.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_CityfolkHoodie.yaml'],
    'Cityfolk Short Jacket 27736 1.2.0 2026-10-17T10-44Z 6ZNKZcc0C.zip': ['archive/pc/mod/PinkyDude_Clothes_CityfolkShortJacket.archive', 'archive/pc/mod/PinkyDude_Clothes_CityfolkShortJacket.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_CityfolkShortJacket.yaml'],
    'Collarless CrystalJock Bomber 27304 1.1.2 2026-11-05T11-50Z zhqmhWTfR.zip': ['archive/pc/mod/PinkyDude_Clothes_CollarlessCrystaljockBomber.archive', 'archive/pc/mod/PinkyDude_Clothes_CollarlessCrystaljockBomber.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_CollarlessCrystaljockBomber.yaml'],
    'David Martinez Pants 35536 1.0.1 2026-10-22T09-30Z n1B61wwNg.zip': ['archive/pc/mod/PinkyDude_Clothes_DavidPants.archive', 'archive/pc/mod/PinkyDude_Clothes_DavidPants.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_DavidPants.yaml'],
    'Deceptious Quest Core 7831 3.3.3 2026-10-27T04-49Z E91D9ddiK.zip': ['archive/pc/mod/zDeceptiousQuestCore.archive', 'archive/pc/mod/zDeceptiousQuestCore.archive.xl'],
    "Dexter's Pants 28660 1.2.0 2026-10-19T08-34Z MTheTjjIT.zip": ['archive/pc/mod/PinkyDude_Clothes_DexterFit_pants.archive', 'archive/pc/mod/PinkyDude_Clothes_DexterFit_pants.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_DexterFit_pants.yaml'],
    "Dexter's Shoes-28660-1-1775376200.zip": ['archive/pc/mod/PinkyDude_Clothes_DexterFit_shoes.archive', 'archive/pc/mod/PinkyDude_Clothes_DexterFit_shoes.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_DexterFit_shoes.yaml'],
    "Dexter's Vest 28660 1.2.0 2026-10-19T08-34Z 5em9eoo0R.zip": ['archive/pc/mod/PinkyDude_Clothes_DexterFit_vest.archive', 'archive/pc/mod/PinkyDude_Clothes_DexterFit_vest.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_DexterFit_vest.yaml'],
    'Equipment-EX 6945 1.2.10 2026-10-25T21-07Z k8Iw8mmPd.zip': ['archive/pc/mod/EquipmentEx.archive', 'archive/pc/mod/EquipmentEx.archive.xl', 'r6/config/redsUserHints/EquipmentEx.toml', 'r6/scripts/EquipmentEx/EquipmentEx.Global.reds', 'r6/scripts/EquipmentEx/EquipmentEx.reds', 'r6/scripts/EquipmentEx/LICENSE'],
    'EquipmentEx-HideHubButtons-6945-1-0-1778915785.zip': ['r6/scripts/EquipmentEx/EquipmentEx.HideHubButtons.reds'],
    'FAIRYEXE DOLLY GOGO MINIDRESSES 37279 2 2026-11-05T04-12Z xNHtNXZcV.rar': ['0_FAIRYEXE_DOLLY_GOGO_MINIDRESSES/Dolly Go-Go Mini Dresses - Codes.txt', '0_FAIRYEXE_DOLLY_GOGO_MINIDRESSES/archive/pc/mod/FAIRYEXE_DOLLY_GOGO_MINIDRESSES.archive', '0_FAIRYEXE_DOLLY_GOGO_MINIDRESSES/archive/pc/mod/fairyexe_dolly_gogo_minidresses.xl', '0_FAIRYEXE_DOLLY_GOGO_MINIDRESSES/r6/tweaks/fairyexe/fairyexe_dolly_gogo_minidresses.yaml'],
    'FIGI6 VAZ1111 Oka Yozakura 36381 4 2026-11-03T12-57Z G5yE5CSBd.zip': ['archive/pc/mod/FIGI6_Yozakura.archive', 'bin/x64/plugins/cyber_engine_tweaks/mods/FIGI6_Oka/init.lua', 'r6/scripts/FIGI6_Oka/Localization.reds', 'r6/tweaks/FIGI6_Oka/vaz1111_oka.yaml'],
    'Goliath Coat 36516 1.0.0 2026-10-30T12-23Z FKtYKrCnU.zip': ['archive/pc/mod/PinkyDude_Clothes_GoliathCoat.archive', 'archive/pc/mod/PinkyDude_Clothes_GoliathCoat.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_GoliathCoat.yaml'],
    'GR YARIS Rocket Bunny Kit 34357 3.2 2026-10-20T20-01Z 6ZNKZccrN.zip': ['archive/pc/mod/00_Toyota_Yaris_GR_RocketBunny.archive'],
    'Immersive Audio Distance (2.31) 36809 1.2.0 2026-11-07T13-09Z X32s3EBoo.zip': ['archive/pc/mod/ImmersiveAudioDistance.archive', 'r6/scripts/Immersive Audio Distance/ImmersiveAudioDistance.reds'],
    'Immersive Voice Distance (2.5) 36809 1.2.0 2026-11-07T13-09Z NEnvE30eR.zip': ['archive/pc/mod/ImmersiveAudioDistance.archive', 'r6/scripts/Immersive Audio Distance/ImmersiveAudioDistance.reds'],
    'Indiana Jones Outfit 34748 1.0.0 2026-10-06T10-59Z zhqmhW33v.zip': ['archive/pc/mod/PinkyDude_Clothes_IndianaJonesOutfit.archive', 'archive/pc/mod/PinkyDude_Clothes_IndianaJonesOutfit.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_IndianaJonesOutfit.yaml'],
    "Jackie's Jacket 31662 1.0.0 2026-07-17T16-30Z Co8doeAFo.zip": ['archive/pc/mod/PinkyDude_Clothes_JackiesJacket.archive', 'archive/pc/mod/PinkyDude_Clothes_JackiesJacket.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_JackiesJacket.yaml'],
    'Knife Bandolier-26000-1-0-2-1771242764.zip': ['archive/pc/mod/PinkyDude_Clothes_KnifeBandolier.archive', 'archive/pc/mod/PinkyDude_Clothes_KnifeBandolier.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_KnifeBandolier.yaml'],
    "Korben's Jacket 27709 1.1.0 2026-10-17T10-39Z IieOiggu9.zip": ['archive/pc/mod/PinkyDude_Clothes_TFEC_KorbenJacket.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_KorbenJacket.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_KorbenJacket.yaml'],
    "Korben's Tank Top 27709 1.1.0 2026-10-17T10-39Z hF7PF44K6.zip": ['archive/pc/mod/PinkyDude_Clothes_TFEC_KorbenTanktop.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_KorbenTanktop.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_KorbenTanktop.yaml'],
    'Lamborghini Countach Liberty Walk 1.0 37235 1 2026-11-04T08-35Z LACBAImkA.zip': ['archive/pc/mod/countach_lbwk.archive', 'archive/pc/mod/countach_lbwk.archive.xl', 'r6/scripts/xaires_countach_lbwk/countach_lbwk.reds', 'r6/tweaks/xaires/countach_lbwk.yaml'],
    'Lamborghini Countach LPI 800 4 1.0 37234 1 2026-11-04T08-29Z Z0ER0Bwn3.zip': ['archive/pc/mod/countach.archive', 'archive/pc/mod/countach.archive.xl', 'r6/scripts/xaires_countach/countach.reds', 'r6/tweaks/xaires/countach.yaml'],
    'Latex Succubus Tail 32638 1.0.0 2026-08-13T14-39Z G5yE5Ctn9.zip': ['archive/pc/mod/PinkyDude_Clothes_LatexSuccubus_tail.archive', 'archive/pc/mod/PinkyDude_Clothes_LatexSuccubus_tail.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_LatexSuccubus_tail.yaml'],
    "Leeloo's Croptop 27709 1.1.0 2026-10-17T10-39Z KRvfRxxXW.zip": ['archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooCroptop.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooCroptop.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_LeelooCroptop.yaml'],
    "Leeloo's Pants-27709-1-0-0-1772729872.zip": ['archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooPants.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooPants.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_LeelooPants.yaml'],
    "Leeloo's Rubber Suspenders 27709 1.1.0 2026-10-17T10-39Z LACBAIIgM.zip": ['archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooRuuberSuspenders.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooRuuberSuspenders.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_LeelooRuuberSuspenders.yaml'],
    "Leeloo's Strap Bodysuit 27709 1.1.0 2026-10-17T10-38Z SlR4l66ch.zip": ['archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooStrapBodysuit.archive', 'archive/pc/mod/PinkyDude_Clothes_TFEC_LeelooStrapBodysuit.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TFEC_LeelooStrapBodysuit.yaml'],
    'Livery 2-25997-1-0-1764883469.7z': ['archive/pc/mod/Livery_2.archive'],
    'manufacturers 7855 1.1 2026-10-31T22-56Z rxs7xRes9.zip': ['archive/pc/mod/car_manuf.archive'],
    'Master Chief Evolved Suit 33439 1.1.0 2026-09-04T08-36Z ujWojTWGT.zip': ['archive/pc/mod/PinkyDude_Clothes_MasterChiefEvolvedSuit.archive', 'archive/pc/mod/PinkyDude_Clothes_MasterChiefEvolvedSuit.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_MasterChiefEvolvedSuit.yaml'],
    'ND_Accessories_store 14299 1.8 2026-09-24T19-58Z 9ka2kytLJ.zip': ['archive/pc/mod/ND_Accessories_store.archive', 'r6/scripts/ND_Accessories_store.reds'],
    'ND_AirPods_Max_FemV-28288-1-1-1776453640.zip': ['ND_AirPods_Max item codes.txt', 'archive/pc/mod/ND_AirPods_Max_FemV.archive', 'archive/pc/mod/ND_AirPods_Max_FemV.xl', 'r6/tweaks/nola_dreamer/ND_AirPods_Max_FemV.yaml'],
    'ND_Barbed_accessories_BothV-14371-1-0-1714058490.zip': ['archive/pc/mod/ND_Barbed_accessories_BothV.archive', 'archive/pc/mod/ND_Barbed_accessories_BothV.xl', 'r6/tweaks/nola_dreamer/ND_Barbed_accessories_BothV.yaml'],
    'ND_Bracelets_Collection_FemV-16722-1-0-1729405657.zip': ['archive/pc/mod/ND_Bracelets_Collection_FemV.archive', 'archive/pc/mod/ND_Bracelets_Collection_FemV.xl', 'r6/tweaks/nola_dreamer/ND_Bracelets_Collection_FemV.yaml'],
    'ND_heart_choker_garters_FemV-11685-1-1-1763540890.zip': ['ND_heart_choker_garters Item codes.txt', 'archive/pc/mod/ND_heart_choker_garters_FemV.archive', 'archive/pc/mod/nd_heart_choker_garters.xl', 'r6/tweaks/nola_dreamer/nd_heart_choker_garters.yaml'],
    'ND_Mini_dress_with_glasses_FemV-15704-1-1-1747683086.zip': ['archive/pc/mod/ND_Mini_dress_with_glasses_FemV.archive', 'archive/pc/mod/ND_Mini_dress_with_glasses_FemV.xl', 'r6/tweaks/nola_dreamer/ND_Mini_dress_with_glasses_FemV.yaml'],
    'ND_Moon_accessories_FemV-14324-1-0-1713729065.zip': ['archive/pc/mod/ND_Moon_accessories_FemV.archive', 'archive/pc/mod/ND_Moon_accessories_FemV.xl', 'r6/tweaks/nola_dreamer/ND_Moon_accessories_FemV.yaml'],
    'ND_Spiked_Collar_BothV-14269-1-1-1713545051.zip': ['archive/pc/mod/ND_Spiked_Collar_BothV.archive', 'archive/pc/mod/ND_Spiked_Collar_BothV.xl', 'r6/tweaks/nola_dreamer/ND_Spiked_Collar_BothV.yaml'],
    'PinkyBlume - Croptop-27455-1-1771261287.zip': ['archive/pc/mod/PinkyBlume_Clothes_Croptop.archive', 'archive/pc/mod/PinkyBlume_Clothes_Croptop.xl', 'r6/tweaks/PinkyBlume/PinkyBlume_Clothes_Croptop.yaml'],
    'S14 Nomad Main files and Livery 1 25997 1.1 2026-10-31T10-30Z UQrhQSION.7z': ['archive/pc/mod/ctrlsec_s14unbound_nomad.archive', 'archive/pc/mod/ctrlsec_s14unbound_nomad.xl', 'archive/pc/mod/ctrlsec_s14unbound_nomad_livery.archive', 'bin/x64/plugins/cyber_engine_tweaks/mods/Dedka Auto Shop/cars/ra5392.json', 'r6/tweaks/ctrlsec/ctrlsec_UnboundS14_Nomad.yaml'],
    'Saul Pants-27128-1-0-3-1770378839.zip': ['archive/pc/mod/PinkyDude_Clothes_SaulsPants.archive', 'archive/pc/mod/PinkyDude_Clothes_SaulsPants.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_SaulsPants.yaml'],
    'Stinky Bootcut Jeans-26050-1-0-1-1770379979.zip': ['archive/pc/mod/PinkyDude_Clothes_StinkyBootcutJeans.archive', 'archive/pc/mod/PinkyDude_Clothes_StinkyBootcutJeans.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_StinkyBootcutJeans.yaml'],
    'Stinky Burnt Top 20042 2.1.0 2026-10-17T10-54Z UQrhQSS6a.zip': ['archive/pc/mod/PinkyDude_Clothes_StinkyBurntTop.archive', 'archive/pc/mod/PinkyDude_Clothes_StinkyBurntTop.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_StinkyBurntTop.yaml'],
    'Stinky Croptop 26048 1.1.0 2026-10-17T10-50Z cB3xB00GX.zip': ['archive/pc/mod/PinkyDude_Clothes_StinkyCroptop.archive', 'archive/pc/mod/PinkyDude_Clothes_StinkyCroptop.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_StinkyCroptop.yaml'],
    'Stinky Leather Jeans-26818-1-0-1-1770379415.zip': ['archive/pc/mod/PinkyDude_Clothes_StinkyLeatherJeans.archive', 'archive/pc/mod/PinkyDude_Clothes_StinkyLeatherJeans.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_StinkyLeatherJeans.yaml'],
    'Stinky Mechanic Pants-16402-2-0-2-1771242914.zip': ['archive/pc/mod/PinkyDude_Clothes_StinkyMechanicPants.archive', 'archive/pc/mod/PinkyDude_Clothes_StinkyMechanicPants.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_StinkyMechanicPants.yaml'],
    'Stinky Quilted Pants-26049-1-0-1-1770379701.zip': ['archive/pc/mod/PinkyDude_Clothes_StinkyQuiltedPants.archive', 'archive/pc/mod/PinkyDude_Clothes_StinkyQuiltedPants.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_StinkyQuiltedPants.yaml'],
    'Stinky Slashed Top 12757 2.1.0 2026-10-17T10-55Z gMz5MuuTP.zip': ['archive/pc/mod/PinkyDude_Clothes_StinkySlashedtop.archive', 'archive/pc/mod/PinkyDude_Clothes_StinkySlashedtop.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_StinkySlashedtop.yaml'],
    'STREET NINJA REMAKE - 1.14.0 ItemIDs Catalog (PDF) 36978 1.14.0 2026-11-04T20-14Z q7jg7fF7W.zip': ['Street_Ninja_Remake_1.14.0_Item_Catalog.pdf'],
    'STREET NINJA REMAKE - MAIN 36978 1.14.0 2026-11-04T20-12Z ozVyzbMNx.zip': ['StreetNinja20_CET_spawn_commands.txt', 'StreetNinja20_Collection_README.txt', 'StreetNinja20_Collection_README_RU.txt', 'StreetNinja20_ItemCatalog.tsv', 'StreetNinja20_New_1.13.0_CET.txt', 'StreetNinja20_New_1.14.0_CET.txt', 'StreetNinja20_Updated_1.13.1_CET.txt', 'archive/pc/mod/StreetNinja20_Collection.archive', 'archive/pc/mod/StreetNinja20_Collection.archive.xl', 'r6/tweaks/StreetNinja20_Collection.yaml'],
    'STREET NINJA REMAKE - Palette Handbook (PDF) 36978 1 2026-11-04T16-35Z D2ZS2n3cJ.zip': ['StreetNinja_Palette_Handbook_1.12.0.pdf'],
    'STREET NINJA STREETWEAR SHOP - OPTIONAL 36978 1.12.0 2026-11-04T20-13Z 4rpqrKQy4.zip': ['StreetNinjaStreetwearShop_README.txt', 'archive/pc/mod/StreetNinjaStreetwearShop.archive', 'bin/x64/plugins/cyber_engine_tweaks/mods/StreetNinjaShopOrder/init.lua', 'r6/scripts/StreetNinjaStreetwearShop/StreetNinjaStreetwearShop.reds'],
    'Template and Example files-19679-0-c-1739925604.zip': ['VendorsXL_Example.yaml', 'VendorsXL_Template.yaml'],
    'The RVC00N Dumpster 3 25981 21.0.0 2026-11-06T14-29Z k8Iw8moq3.zip': ['archive/pc/mod/PinkyDude_TheRVC00NDumpster3.archive', 'archive/pc/mod/PinkyDude_TheRVC00NDumpster3.xl', 'r6/scripts/PinkyDude_TheRVC00NDumpster3.reds', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_TheRVC00NDumpster3.yaml'],
    'Toyota Yaris GR All Purpose Drive Spec 34357 3.3 2026-10-29T18-56Z PYMIYq3GS.zip': ['archive/pc/mod/Toyota_Yaris_GR.archive', 'archive/pc/mod/Toyota_Yaris_GR.xl', 'r6/tweaks/toyota_gr_yaris/toyota_gr_yaris.yaml'],
    'Toyota Yaris GR Drift Handling Spec (Tune Only) 34357 1 2026-10-29T18-57Z Co8doe62d.zip': ['r6/tweaks/toyota_gr_yaris/toyota_gr_yaris.yaml'],
    'Traum Team Combi 32329 1.0.0 2026-08-06T11-18Z rxs7xRAva.zip': ['archive/pc/mod/PinkyDude_Clothes_TraumaTeamCombi.archive', 'archive/pc/mod/PinkyDude_Clothes_TraumaTeamCombi.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_TraumaTeamCombi.yaml'],
    'Urban Techwear Outfit - Both V-25512-1-0-1764371099.zip': ['archive/pc/mod/Urban Techwear Outfit.archive', 'archive/pc/mod/veegee_urban_techwear_outfit.xl', 'r6/tweaks/Veegee/veegee_urban_techwear_outfit.yaml', 'veegee_urban_techwear_outfit_code.txt'],
    'uv layout for livery creators-25997-1-1764895541.7z': ['archive/pc/mod/uv_layout_for_livery_creators.archive'],
    'Veegee Shop 3-18890-1-5-2-1779738603.zip': ['Veegee Shop 3/archive/pc/mod/Veegee Shop 3.archive', 'Veegee Shop 3/r6/scripts/veegee_shop_3.reds'],
    'VendorsXL 19679 2.2.0 2026-08-07T15-58Z cB3xB0qjH.zip': ['archive/pc/mod/VendorsXL.archive', 'archive/pc/mod/VendorsXL.archive.xl', 'r6/scripts/VendorsXL/VendorsXL.reds', 'r6/tweaks/##########VendorsXL/##########_VendorsXL.yaml'],
    'Yeehaw Collar Shirt 26873 1.3.0 2026-10-17T10-47Z ymA1m88PG.zip': ['archive/pc/mod/PinkyDude_Clothes_YeehawCollarShirt.archive', 'archive/pc/mod/PinkyDude_Clothes_YeehawCollarShirt.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_YeehawCollarShirt.yaml'],
    'Yeehaw Spur Boots-26982-1-0-1-1770378994.zip': ['archive/pc/mod/PinkyDude_Clothes_YeehawSpurBoots.archive', 'archive/pc/mod/PinkyDude_Clothes_YeehawSpurBoots.xl', 'r6/tweaks/PinkyDude_TheRVC00NDumpster3/PinkyDude_Clothes_YeehawSpurBoots.yaml'],
}


def placeholder(path, archive):
    """Small stand-in contents for a file of a mod archive, by its type, naming the file and the archive
    it came from (two files of one mod may hold the same paths)."""
    leaf = path.rsplit('/', 1)[-1]
    ext = leaf.rsplit('.', 1)[-1].lower() if '.' in leaf else ''
    form = {'archive': b'RDAR %s', 'reds': b'// %s\n', 'lua': b'-- %s\n', 'yaml': b'# %s\n', 'yml': b'# %s\n',
            'xl': b'# %s\n', 'json': b'{"file": "%s"}\n', 'dll': b'MZ %s', 'bnk': b'BKHD %s'}.get(ext, b'%s\n')
    return form.replace(b'%s', ('%s from %s' % (leaf, archive)).encode())

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

    # the installer's add-on sets (--with-flight, --with-mods), shaped like the real releases,
    # and its ADDON_SETS table pointing at them; the Nexus mods are archives named as Nexus names its downloads
    table = []

    def github(comp, sets, kind, rule, probe, ver, name, files):
        path = f'{fix}/gh/{name}'
        zipdir(path, files)
        table.append(f'{comp} 2.5 {sets} {kind} {rule} {probe} {ver} file://{path} {sha(path)}')

    github('redscript', 'flight,mods,eqex', 'lib', '-', 'engine/tools/scc_lib.dll', '0.5.32', 'redscript-v0.5.32-windows.zip', {
        'engine/config/base/scripts.ini': b'[Scripts]\r\nEnableCompilation = "true"\r\n',
        'engine/tools/scc.exe': b'redscript scc 0.5.32',
        'engine/tools/scc_lib.dll': b'redscript lib 0.5.32',
        'r6/config/cybercmd/scc.toml': b'[args]\r\n'})
    make_pe(f'{pe}/axl/ArchiveXL.dll', '1.28.6.0', linker=(14, 44), imports=CRT)
    github('ArchiveXL', 'flight,mods,eqex', 'lib', 'minor', 'red4ext/plugins/ArchiveXL/ArchiveXL.dll', '1.28.6', 'ArchiveXL-1.28.6.zip', {
        'red4ext/plugins/ArchiveXL/ArchiveXL.dll': f'{pe}/axl/ArchiveXL.dll',
        'red4ext/plugins/ArchiveXL/Scripts/ArchiveXL.reds': b'// ArchiveXL 1.28.6\n',
        'r6/config/redsUserHints/ArchiveXL.toml': b'# hints\n'})
    make_pe(f'{pe}/txl/TweakXL.dll', '1.12.0.0', linker=(14, 44), imports=CRT)
    github('TweakXL', 'flight,mods,eqex', 'lib', 'minor', 'red4ext/plugins/TweakXL/TweakXL.dll', '1.12.0', 'TweakXL-1.12.0.zip', {
        'red4ext/plugins/TweakXL/TweakXL.dll': f'{pe}/txl/TweakXL.dll',
        'red4ext/plugins/TweakXL/Scripts/TweakXL.reds': b'// TweakXL 1.12.0\n'})
    make_pe(f'{pe}/il/input_loader.dll', '0.2.6', '2.50', linker=(14, 44), imports=CRT, strings={'Comments': 'Built for 2.50'})
    github('Input_Loader', 'flight', 'lib', 'game', 'red4ext/plugins/input_loader/input_loader.dll', '0.2.6', 'input_loader_v0.2.6.zip', {
        'red4ext/plugins/input_loader/input_loader.dll': f'{pe}/il/input_loader.dll',
        'r6/cache/inputContexts.xml': b'<bindings loader="0.2.6"/>\r\n',
        'r6/cache/inputUserMappings.xml': b'<mappings loader="0.2.6"/>\r\n',
        'engine/config/platform/pc/input_loader.ini': b'[Player/Input]\r\n'})
    make_pe(f'{pe}/ltbf/let_there_be_flight.dll', '0.3.20', '2.50', linker=(14, 44), imports=CRT, strings={'Comments': 'Built for 2.50'})
    github('Let_There_Be_Flight', 'flight', 'mod', 'game', 'red4ext/plugins/let_there_be_flight/let_there_be_flight.dll', '0.3.20',
           'let_there_be_flight_v0.3.20.zip', {
               'red4ext/plugins/let_there_be_flight/let_there_be_flight.dll': f'{pe}/ltbf/let_there_be_flight.dll',
               'red4ext/plugins/let_there_be_flight/packed.reds': b'// LTBF 0.3.20\n',
               'red4ext/plugins/let_there_be_flight/inputs.xml': b'<inputs/>\r\n',
               'red4ext/plugins/let_there_be_flight_uninstall.bat': b'@echo off\r\n'})
    make_pe(f'{pe}/cw/Codeware.dll', '1.21.2.0', linker=(14, 44), imports=CRT)
    github('Codeware', 'mods,eqex', 'lib', 'minor', 'red4ext/plugins/Codeware/Codeware.dll', '1.21.2', 'Codeware-1.21.2.zip', {
        'red4ext/plugins/Codeware/Codeware.dll': f'{pe}/cw/Codeware.dll',
        'red4ext/plugins/Codeware/Scripts/Codeware.reds': b'// Codeware 1.21.2\n',
        'red4ext/plugins/Codeware/LICENSE': b'MIT\n'})
    make_pe(f'{pe}/cet/version.dll', '6.0.0', linker=(14, 44), imports=CRT)
    make_pe(f'{pe}/cet/cyber_engine_tweaks.asi', '1.38.1', 'v1.38.1 [HEAD]', linker=(14, 44), imports=CRT)
    github('Cyber_Engine_Tweaks', 'mods', 'lib', 'minor', 'bin/x64/plugins/cyber_engine_tweaks.asi', '1.38.1', 'cet_1_38_1.zip', {
        'bin/x64/version.dll': f'{pe}/cet/version.dll',
        'bin/x64/global.ini': b'[GlobalSets]\r\n',
        'bin/x64/LICENSE': b'MIT\n',
        'bin/x64/plugins/cyber_engine_tweaks.asi': f'{pe}/cet/cyber_engine_tweaks.asi',
        'bin/x64/plugins/cyber_engine_tweaks/scripts/autoexec.lua': b'-- CET\n',
        'bin/x64/plugins/cyber_engine_tweaks/fonts/Noto.ttf': b'font'})
    make_pe(f'{pe}/ms/mod_settings.dll', '0.2.28', '2.50', linker=(14, 44), imports=CRT)
    github('Mod_Settings', 'mods', 'lib', 'game', 'red4ext/plugins/mod_settings/mod_settings.dll', '0.2.28', 'mod_settings_v0.2.28.zip', {
        'red4ext/plugins/mod_settings/mod_settings.dll': f'{pe}/ms/mod_settings.dll',
        'red4ext/plugins/mod_settings/ModSettings.archive': b'RDAR',
        'red4ext/plugins/mod_settings/ModSettings.archive.xl': b'resource:\n',
        'red4ext/plugins/mod_settings/module.reds': b'module ModSettingsModule\n',
        'red4ext/plugins/mod_settings/packed.reds': b'// Mod Settings 0.2.28\n'})
    github('Audioware', 'mods', 'lib', '-', 'red4ext/plugins/audioware/audioware.dll', '1.11.1', 'Audioware-windows-v1.11.1.zip', {
        'red4ext/plugins/audioware/audioware.dll': b'MZ audioware 1.11.1, no version resource',
        'r6/scripts/Audioware/Service.reds': b'// Audioware 1.11.1\n'})
    # the Nexus mods: the installer's own rows, so that the tests use its file rules and minimum versions
    installer = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'nightcoop-install.sh')
    rows = open(installer, encoding='utf-8').read().split('# >>> add-on sets\n', 1)[1].split('# <<< add-on sets', 1)[0]
    table += [' '.join(r.split()) for r in rows.splitlines() if len(r.split()) == 8 and r.split()[7].startswith('nexus:')]
    write(f'{fix}/addon-sets.txt', '\n'.join(table) + '\n')
    make_pe(f'{pe}/axl-1.28.7/ArchiveXL.dll', '1.28.7.0', linker=(14, 44), imports=CRT)   # a newer copy, installed by hand

    # Downloads, named as Nexus names them: <file name>-<mod id>-<version>-<upload time> until 2026,
    # <file name> <mod id> <version> <YYYY-MM-DDTHH-MMZ> <file key> since (the real files of each mod)
    nx = f'{fix}/nexus'
    zipdir(f'{nx}/Virtual Atelier 2987 1.6.4 2026-10-25T17-42Z HncQn22j7.zip', {
        'archive/pc/mod/VirtualAtelier.archive': b'RDAR', 'archive/pc/mod/VirtualAtelier.archive.xl': b'localization:\n',
        'r6/scripts/virtual-atelier-full/Config.reds': b'// Virtual Atelier 1.6.4\n'})
    zipdir(f'{nx}/Virtual Atelier - Basic-2987-1-2-4-1706771312.zip', {   # the last Basic file, of 2024: too old for 2.5
        'r6/scripts/VirtualAtelier/Basic.reds': b'// basic 1.2.4\n'})
    zipdir(f'{nx}/PUBLICNET-10909-1-2-1-1702220953.zip', {   # A.G.I.S.'s main file, wrapped in a folder, with a read-me
        'AGIS/r6/scripts/AGIS/agis.reds': b'// agis publicnet\n', 'AGIS/readme.txt': b'read me\n'})
    zipdir(f'{nx}/BLACKWALL-10909-1-2-1-1702221109.zip', {   # another edition, newer: never installed
        'r6/scripts/AGIS_BLACKWALL/agis.reds': b'// agis blackwall\n'})
    zipdir(f'{nx}/Darks Night City Marketplace-4433-2-3-0-1757877636.zip', {'r6/scripts/NCMarketplace/stores.reds': b'// ncm\n'})
    zipdir(f'{nx}/Quick Stash-30016-v1-1-1779816414.zip', {   # a version written with a v
        'bin/x64/plugins/cyber_engine_tweaks/mods/QuickStash/init.lua': b'-- quick stash\n'})
    zipdir(f'{nx}/No Intro Videos-533-0-5-1721546294.zip', {'archive/pc/mod/NoIntroVideos.archive': b'RDAR'})
    zipdir(f'{nx}/No Intro Videos - redscript-533-0-8-1760416944.zip', {   # the redscript file: never installed
        'r6/scripts/NoIntroVideos/NoIntroVideos.reds': b'// no intro, redscript\n'})
    zipdir(f'{fix}/nexus-bad/No Intro Videos-533-0-6-1730000000.zip', {'readme.txt': b'install by hand\n'})   # no game folders
    zipdir(f'{nx}/Virtual Car Dealer 4454 2.3.0 2026-10-25T11-18Z lcXrcZZMt.zip', {
        'archive/pc/mod/VirtualCarDealer.archive': b'RDAR',
        'r6/scripts/VirtualCarDealer/core/CarDealer-System.reds': b'// virtual car dealer 2.3.0\n'})
    zipdir(f'{nx}/Native Settings UI 1.97 3518 1.97 2026-10-22T15-26Z cB3xB00Va.zip', {
        'bin/x64/plugins/cyber_engine_tweaks/mods/nativeSettings/init.lua': b'-- native settings ui 1.97\n'})
    cd = 'bin/x64/plugins/cyber_engine_tweaks/mods'
    zipdir(f'{nx}/CyberDrift 2.0 Light for game ver. 2.31 8306 2.31 2026-08-03T18-29Z 4rpqrKU17.zip', {
        f'{cd}/CyberDrift Light/init.lua': b'-- cyber drift light\n',
        f'{cd}/CyberDrift Light/custom/car_list.json': b'{"cars": []}\n',
        f'{cd}/CyberDrift Light/db.sqlite3': b''})
    zipdir(f'{nx}/Cyber Drift 2.0 for game ver. 2.31 8306 2.31 2026-07-03T23-03Z ymA1m8KJ2.zip', {
        f'{cd}/CyberDrift/init.lua': b'-- cyber drift, all parameters\n'})
    zipdir(f'{nx}/Cyber Drift 2.0 for game ver. 2.5 8306 2.5 2026-11-03T10-00Z Rq4tLm9Wx.zip', {   # newer, not the Light file
        f'{cd}/CyberDrift/init.lua': b'-- cyber drift, all parameters, 2.5\n'})
    zipdir(f'{nx}/Cyber Drift for game 2.3 TweakXL-8306-2-3-1754137206.zip', {'r6/tweaks/CyberDrift/drift.yaml': b'# 2.3\n'})

    def dav(chunk):   # Drive an Aerial Vehicle, with the files it writes to while the game runs
        d = f'{cd}/DriveAerialVehicle'
        return {'archive/pc/mod/DriveAerialVehicle.archive': b'RDAR', f'{d}/init.lua': b'-- dav\n',
                f'{d}/Data/user_setting_v3.json': b'{"language": "default"}\n',
                f'{d}/Data/map_bin/chunk_0_0.bin': chunk, f'{d}/Data/map_bin/chunk_0_1.bin': b'map 0 1',
                'r6/audioware/DriveAerialVehicle/manifest.yml': b'version: 1.0.0\n',
                'r6/scripts/DriveAerialVehicle/DriveAerialVehicle.reds': b'// dav\n',
                'r6/tweaks/DriveAerialVehicle/dav_default_model.yaml': b'Vehicle.av_rayfield_excalibur_dav_dummy: {}\n',
                'red4ext/plugins/DriveAerialVehicle/DriveAerialVehicle.dll': b'MZ dav'}
    zipdir(f'{nx}/Drive an Aerial Vehicle 13842 3.5.0 2026-10-26T16-09Z mPgaPVV1e.zip', dav(b'map 0 0 v1'))
    zipdir(f'{fix}/nexus-later/Drive an Aerial Vehicle 13842 3.5.1 2026-11-02T09-30Z Zx81kQp0a.zip', dav(b'map 0 0 v2'))

    # clothing stores and outfits, car and bike packs, and Vehicle Customizer: the real file names
    # of each mod's main and other files (the .rar of the bikes and the .7z of Material and Texture
    # Override are zips here, so that the suite needs no bsdtar)
    st = f'{fix}/style'
    zipdir(f'{st}/All Vanilla Clothes Atelier Store-5544-v1-0-1738160755.zip', {
        'r6/scripts/AllVanillaClothes/store.reds': b'// all vanilla clothes\n'})
    zipdir(f'{st}/IconicShops 7215 3.6.2 2026-11-04T06-43Z FKtYKrCFm.zip', {
        'archive/pc/mod/IconicShop.archive': b'RDAR', 'r6/scripts/iconicshop/shops/top.reds': b'// iconic\n',
        'r6/tweaks/iconicShop/duplicateItems.yaml': b'Items: {}\n'})
    zipdir(f'{st}/Zenitex Virtual Atelier 10090 4.13 2026-08-28T15-44Z gMz5MuNQO.zip', {
        'archive/pc/mod/scorpion_zenitex_virtual_atelier.archive': b'RDAR',
        'r6/scripts/ScorpionTank/scorpion_zenitex_virtual_atelier.reds': b'// zenitex store\n'})

    def gear(name, item):   # a Zenitex outfit: its archive, its TweakXL records, and a list of codes
        return {f'archive/pc/mod/{item}.archive': b'RDAR', f'archive/pc/mod/{item}.archive.xl': b'localization:\n',
                f'r6/tweaks/scorpiontank/{item}.yaml': f'Items.{item}: {{}}\n'.encode(), 'codes.txt': b'Game.AddToInventory\n'}
    zipdir(f'{st}/Zenitex Ballistic Mask-12422-4-1-1780618307.zip', gear('mask', 'zenitex_mask'))
    zipdir(f'{st}/Zenitex Ballistic Mask - Alt. Colors-12422-4-1-1780618751.zip', {'r6/tweaks/scorpiontank/zenitex_mask_alt.yaml': b'#\n'})
    zipdir(f'{st}/Zenitex Ballistic Mask - GS-12422-4-1-1780618658.zip', gear('mask', 'zenitex_mask_gs'))
    zipdir(f'{st}/Zenitex Tactical Harness 9774 4.0 2026-08-11T13-01Z 9ka2kyJHP.zip', gear('harness', 'zenitex_harness'))
    zipdir(f'{st}/Zenitex Tactical Harness - GS 9774 4.0 2026-08-11T13-02Z xNHtNXgf4.zip', gear('harness', 'zenitex_harness_gs'))
    zipdir(f'{st}/Zenitex Combat Jacket 19119 2.0.1 2026-08-03T19-10Z SlR4l6sri.zip', gear('jacket', 'zenitex_jacket'))
    zipdir(f'{st}/Zenitex Armor Pads 12044 4.1 2026-06-20T11-45Z MTheTj2uo.zip', gear('pads', 'zenitex_pads'))
    zipdir(f'{st}/Zenitex Panam Pants 10842 4.0 2026-08-09T13-53Z PYMIYqZfI.zip', gear('pants', 'zenitex_pants'))
    zipdir(f'{st}/Zenitex Combat Gloves-19432-2-0-1-1780856480.zip', gear('gloves', 'zenitex_gloves'))
    zipdir(f'{st}/Zenitex Combat Gloves - Garment Support-19432-2-0-1780856305.zip', gear('gloves', 'zenitex_gloves_gs'))
    zipdir(f'{st}/Comfy Boots - Female V and Male V-11212-1-1-1701090170.zip', gear('boots', 'comfy_boots'))
    zipdir(f'{st}/Comfy Boots - Gymfiend-11212-1-1-1704816258.zip', gear('boots', 'comfy_boots_gymfiend'))
    zipdir(f'{st}/Virtual Car Dealer - Car Pack-4625-1-8-2-1674936277.zip', {   # Car Pack 1, as Nexus names it
        'archive/pc/mod/vcd_car_pack_1.archive': b'RDAR', 'r6/tweaks/VirtualCarDealer/car_pack_1.yaml': b'Vehicle.v_pack1: {}\n'})
    zipdir(f'{st}/Virtual Car Dealer - Car Pack 2-4625-1-9-0-1675361670.zip', {
        'archive/pc/mod/vcd_car_pack_2.archive': b'RDAR', 'r6/tweaks/VirtualCarDealer/car_pack_2.yaml': b'Vehicle.v_pack2: {}\n'})
    zipdir(f'{st}/Cyberpunk Bikes - Edge 14719 1.03 2026-10-17T09-22Z k8Iw8mmHf.zip', {
        'archive/pc/mod/Methodd_Edge.archive': b'RDAR', 'r6/tweaks/Methodd/Methodd_Edge/mthdd_Methodd_Edge.yaml': b'Vehicle.v_edge: {}\n'})
    zipdir(f'{st}/VehicleExitFix-22786-1-0-1752937333.zip', {'r6/tweaks/VehicleExitFix/exit.yaml': b'# exit fix\n'})
    zipdir(f'{st}/BDF_DRe_ArchV4-18736-1-3-1766091835.zip', {
        'archive/pc/mod/BDF_DRe_ArchV4.archive': b'RDAR', 'r6/tweaks/BDF/archv4.tweak': b'// arch v4\n'})
    zipdir(f'{st}/BDF_DRe_ArchV4_Mirrors-18736-1-3-1766092481.zip', {'archive/pc/mod/BDF_DRe_ArchV4_Mirrors.archive': b'RDAR'})
    zipdir(f'{st}/dre_cyberhelmets-18736-1-1753577287.zip', {'archive/pc/mod/dre_cyberhelmets.archive': b'RDAR'})
    zipdir(f'{st}/VMF-28744-1-0-1775609654.zip', {'r6/scripts/VMF/vmf.reds': b'// vehicle manufacturer fix\n'})
    zipdir(f'{st}/KRNLNIK Toyota Supra MK5 HKS Widebody-12652-1-0-5-Minor-1775612074.zip', {
        'archive/pc/mod/krnlnik_supra.archive': b'RDAR', 'r6/tweaks/krnlnik/supra.yaml': b'Vehicle.v_supra: {}\n'})
    zipdir(f'{st}/Supra Colors-12652-1-0-1706484697.zip', {'r6/tweaks/krnlnik/supra_colors.yaml': b'#\n'})
    zipdir(f'{st}/Material and Texture Override-5266-1-2-1695907754.zip', {'archive/pc/mod/MaterialTextureOverride.archive': b'RDAR'})
    zipdir(f'{st}/Material and Texture Override (REDmod)-5266-1-2-1695948618.zip', {'mods/MaterialTextureOverride/archives/mto.archive': b'RDAR'})
    zipdir(f'{st}/Porsche 911 GT3 RS (Main File)you need this-11180-1-2-1703436412.zip', {
        'archive/pc/mod/porsche_gt3rs.archive': b'RDAR', 'r6/tweaks/porsche/gt3rs.yaml': b'Vehicle.v_gt3rs: {}\n'})
    zipdir(f'{st}/Porsche 911 GT3 RS Grey_Red-11180-1-2-1703436491.zip', {'archive/pc/mod/porsche_gt3rs_grey_red.archive': b'RDAR'})
    vc = 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCustomizerSVE'
    zipdir(f'{st}/Vehicle Customizer SVE 3dot0-9034-3-0-1738340467.zip', {
        f'{vc}/init.lua': b'-- vehicle customizer 3.0\n', f'{vc}/data/appearances.json': b'{"Quadra": ["a", "b"]}\n',
        f'{vc}/saved.json': b'{}\n'})
    zipdir(f'{st}/Vehicle Customizer SVE 3dot1 9034 3.1 2026-09-21T11-33Z tvQTvsQ74.zip', {   # the 3.1 update, in a folder
        f'Vehicle Customizer SVE 3dot1/{vc}/init.lua': b'-- vehicle customizer 3.1\n'})

    # the third round and Equipment-EX: the real archives' entries (ROUND3); a .rar or .7z is a .zip
    # here, so that the suite needs no bsdtar (the mods7z world unpacks a real 7z where bsdtar is)
    for name, paths in ROUND3.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round3/{zname}', {p: placeholder(p, name) for p in paths})

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
\t\t\t\t\t\t"LaunchOptions"\t\t"gamemoderun %command% --launcher-skip"
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
    write(f'{game}/engine/tools/scc.exe', 'the game\'s own script compiler')   # what redscript replaces
    write(f'{game}/r6/cache/inputContexts.xml', '<bindings/>')                 # and Input Loader
    write(f'{game}/r6/cache/inputUserMappings.xml', '<mappings/>')
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
