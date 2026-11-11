#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fixtures for run-tests.sh: synthetic PE files, archives, a fake Steam tree and Proton.

    mkfixtures.py archives DIR            NightCoop/RED4ext archives, installers, releases.json
    mkfixtures.py world DIR FIX LAYOUT [OPTS]  a home folder with Steam, the game and a Proton prefix

LAYOUT is one of: native (game on a second library, as on a Steam Deck SD card),
flatpak (Flatpak Steam, sandbox paths in Steam's files) or cachyos (both proton-cachyos
packages installed, Steam's default set to Proton 10, no config_info yet). OPTS: see world().
"""
import calendar
import hashlib
import json
import os
import re
import shutil
import struct
import sys
import time
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


# The third round of the mod set (cars, the clothes of The RVC00N Dumpster 3, Nola Dreamer and Street
# Ninja, Impact FX, Immersive Audio Distance) and Equipment-EX: each download's real file name and
# entries, read from the archive itself (or, for a .rar or .7z, its Nexus manifest), with the files a
# rule must pass over. Veegee's and Dolly Go-Go's clothes, made for photo mode, are downloads the set
# passes over (and that an earlier table installed). Contents are stand-ins (see placeholder).
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

# The fourth round (the seven Zenitex outfits and two Zenitex accessories, Nola Dreamer's boutique,
# hairstyles, and raem's jewellery for Equipment-EX): each download's real file name and entries, read
# from the archive itself, with the files a rule must pass over. Contents are stand-ins (see placeholder).
ROUND4 = {
    '(masc) necklace 6 higher fit-15861-1-2-1728769985.zip': ['archive/pc/mod/rm_00_acc_set_doll_MESH_masc_neck 6 higher fit.archive'],
    '1. AIO - ALL IN ONE - HYST HAIR COLLECTION-21766-1-2-1762627999.zip': ['archive/pc/mod/Hyst_Iconic_Hair_CCXL.archive', 'archive/pc/mod/Hyst_Karina_Hair_CCXL.archive', 'archive/pc/mod/Hyst_Kim_Hair_CCXL.archive', 'archive/pc/mod/Hyst_Mina_Hair_CCXL.archive', 'archive/pc/mod/Hyst_Spark_Hair_CCXL.archive', 'archive/pc/mod/Hyst_Stellar_Hair_CCXL.archive', 'archive/pc/mod/Hyst_Winter_Hair_CCXL.archive', 'archive/pc/mod/hyst_iconic_hair_ccxl.xl', 'archive/pc/mod/hyst_karina_hair_ccxl.xl', 'archive/pc/mod/hyst_kim_hair_ccxl.xl', 'archive/pc/mod/hyst_mina_hair_ccxl.xl', 'archive/pc/mod/hyst_spark_hair_ccxl.xl', 'archive/pc/mod/hyst_stellar_hair_ccxl.xl', 'archive/pc/mod/hyst_winter_hair_ccxl.xl'],
    'Accessories - Main Store 14210 2.0 2026-07-22T17-45Z q7jg7fhhj.zip': ['archive/pc/mod/rm_!atelier_accessories_main.archive', 'r6/scripts/raem/rm_atelier_accessories_main.reds'],
    'Accessories - Pearl Jewelry 14210 2.0 2026-07-22T17-45Z JSKWSQpp5.zip': ['archive/pc/mod/rm_!atelier_accessories_pearls.archive', 'r6/scripts/raem/rm_atelier_accessories_pearls.reds'],
    'CCXL - HAIR MEGAPAK-19197-5-0-0-1744339844.zip': ['CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - # HAIR MEGAPAK.archive', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - CAROLINE INVERTED BOB.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - CHAERI BLUNT BANG.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - FAMKE MODERN LAYERS - V1.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - FAMKE MODERN LAYERS - V2.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - KIMBER SPACE BUNS.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - KUROTANI MICROBOB - V1.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - KUROTANI MICROBOB - V2.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - KUROTANI MICROBOB - V3.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - MELANIE GLAM PONY - V1.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - MELANIE GLAM PONY - V2.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - RICHIE MINI MULLET.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - SABRINA MESSY PONY - V1.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - SABRINA MESSY PONY - V2.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - SASHA MODERN BLOWOUT - V1.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - SASHA MODERN BLOWOUT - V2.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - SOFIA SOFT LOB - V1.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - SOFIA SOFT LOB - V2.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - SOFIA SOFT LOB - V3.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - WINONA CROP - V1.xl', 'CCXL - MEGAPAK/archive/pc/mod/MELUMINARY - CCXL - WINONA CROP - V2.xl'],
    'CCXL - WINONA-19197-5-0-0-1744340175.zip': ['CCXL - WINONA/MELUMINARY - CCXL - WINONA CROP - V1 + V2.archive', 'CCXL - WINONA/MELUMINARY - CCXL - WINONA CROP - V1.xl', 'CCXL - WINONA/MELUMINARY - CCXL - WINONA CROP - V2.xl'],
    'CCXL Sub Hair Pack - AllInOne-19268-1-09-1772653636.rar': ['archive/pc/mod/CCXL_Sub_HairPack_Frost.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Frost.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Fuze.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Fuze.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Glace.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Glace.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Heart.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Heart.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Hope.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Hope.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Lightning.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Lightning.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Lunar.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Lunar.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Mercy.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Mercy.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Nuclear.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Nuclear.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Poison.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Poison.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Stealth.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Stealth.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Surge.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Surge.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Volt.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Volt.xl', 'archive/pc/mod/CCXL_Sub_HairPack_Wolf.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Wolf.xl'],
    'CCXL Sub Hair Pack - Wolf-19268-1-09-1772653934.zip': ['archive/pc/mod/CCXL_Sub_HairPack_Wolf.archive', 'archive/pc/mod/CCXL_Sub_HairPack_Wolf.xl'],
    'Chain Jewelry - Main-15861-1-2-1728769757.zip': ['archive/pc/mod/rm_acc_set_doll.archive', 'archive/pc/mod/rm_acc_set_doll.xl', 'r6/tweaks/raem/rm_acc_set_doll.yaml'],
    'Clothes - Main Store 14210 2.0 2026-07-22T17-47Z k8Iw8mCCl.zip': ['archive/pc/mod/rm_!atelier_clothes_main.archive', 'r6/scripts/raem/rm_atelier_clothes_main.reds'],
    'Emo Wolfcut - CCXL-16697-2-0-1747433013.zip': ['archive/pc/mod/NUT_emowolf_ccxl.archive', 'archive/pc/mod/NUT_wolfcut_emo_ccxl.xl'],
    'Emo Wolfcut - FV-16697-1-0-1726897852.zip': ['NUT_F40-41_emo_wolfcut/archive/pc/mod/NUT_F40_wolfemo_long.archive', 'NUT_F40-41_emo_wolfcut/archive/pc/mod/NUT_F41_wolfemo_short.archive'],
    'Emo Wolfcut - MV-16697-1-0-1726897884.zip': ['NUT_M41-42_emo_wolfcut/NUT_M41-42_EMO/NUT_M41_wolfemo_short.archive', 'NUT_M41-42_emo_wolfcut/NUT_M41-42_EMO/NUT_M42_wolfemo_long.archive'],
    'HAIR 01 - Slickback Undercut-19907-1-0b-1759251188.zip': ['archive/pc/mod/HALK_Hair_SlickBackUndercut.archive', 'archive/pc/mod/HALK_Hair_SlickBackUndercut.xl'],
    'HAIR 02 - Sidewave Undercut-19907-1-0-1740311599.zip': ['archive/pc/mod/HALK_CCXL_Hair_SideWaveUndercut.archive', 'archive/pc/mod/HALK_CCXL_Hair_SideWaveUndercut.xl'],
    'HAIR 03 - ManBun Undercut-19907-1-0a-1741536842.zip': ['archive/pc/mod/HALK_CCXL_Hair_ManBunUndercut.archive', 'archive/pc/mod/HALK_CCXL_Hair_ManBunUndercut.xl'],
    'HAIR 04 - Slickback Braids Undercut-19907-1-1-1741536363.zip': ['archive/pc/mod/HALK_CCXL_Hair_SlickBackBraidsUndercut.archive', 'archive/pc/mod/HALK_CCXL_Hair_SlickBackBraidsUndercut.xl'],
    'Hime Long Jelly - CCXL-16697-2-0-1747433240.zip': ['archive/pc/mod/NUT_hime_jelly_ccxl.archive', 'archive/pc/mod/NUT_hime_jelly_ccxl.xl'],
    'Hime Medium - CCXL-16697-2-0-1747433180.zip': ['archive/pc/mod/NUT_hime_medium.xl', 'archive/pc/mod/NUT_hime_medium_ccxl.archive'],
    'Hime Short - CCXL-16697-2-0-1747433137.zip': ['archive/pc/mod/NUT_hime_short.xl', 'archive/pc/mod/NUT_hime_short_ccxl.archive'],
    'Kim Hair-21766-1-0-1762627938.zip': ['archive/pc/mod/Hyst_Kim_Hair_CCXL.archive', 'archive/pc/mod/hyst_kim_hair_ccxl.xl'],
    'Messy Wolfcut - CCXL-16697-2-0-1747432969.zip': ['archive/pc/mod/NUT_messywolf_ccxl.archive', 'archive/pc/mod/NUT_wolfcut_messy_ccxl.xl'],
    'Military Armored Ballistic Vest - Alt. Vest-14348-3-2-1742087043.zip': ['archive/pc/mod/0_scorpion_military_armored_vest_addon_alternate_vest.archive'],
    'Military Armored Ballistic Vest - Garment Support-14348-3-2-1742087108.zip': ['archive/pc/mod/0_scorpion_military_armored_ballistic_vest_addon_garment_support.archive'],
    'Military Ballistic Vest-14348-3-6-1757019003.zip': ['archive/pc/mod/scorpion_military_armored_ballistic_vest.archive', 'archive/pc/mod/scorpion_military_armored_ballistic_vest.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_military_armored_ballistic_vest.yaml'],
    'Military Combat Armor-13212-3-3-1757018748.zip': ['archive/pc/mod/scorpion_military_combat_armor.archive', 'archive/pc/mod/scorpion_military_combat_armor.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_military_combat_armor.yaml'],
    'Military Combat Boots-14781-3-4-1757019093.zip': ['archive/pc/mod/scorpion_military_combat_boots.archive', 'archive/pc/mod/scorpion_military_combat_boots.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_military_combat_boots.yaml'],
    'Military Pistol Holsters-18002-1-5-1757023050.zip': ['archive/pc/mod/scorpion_military_dual_pistol_holsters.archive', 'archive/pc/mod/scorpion_military_dual_pistol_holsters.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_military_dual_pistol_holsters.yaml'],
    'ND_female_virtual_boutique 5114 7.6 2026-10-05T16-51Z AgoGgilxQ.zip': ['archive/pc/mod/ND_female_virtual_boutique.archive', 'r6/scripts/ND_female_virtual_boutique.reds'],
    'ND_male_virtual_boutique-5114-1-2-1713209715.zip': ['archive/pc/mod/ND_male_virtual_boutique.archive', 'r6/scripts/ND_male_virtual_boutique.reds'],
    'Ops-Core FAST Helmet - Garment Support-13557-3-1-1750787316.zip': ['archive/pc/mod/0_scorpion_military_opscore_helmet_addon_garment_support.archive'],
    'Ops-Core FAST Helmet-13557-3-4-1757020329.zip': ['archive/pc/mod/scorpion_military_opscore_helmet.archive', 'archive/pc/mod/scorpion_military_opscore_helmet.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_military_opscore_helmet.yaml'],
    'Preem Hair (2K) 8223 3.0.0b 2026-10-21T01-21Z RXDpXNNts.zip': ['archive\\pc\\mod\\###-PreemHair.archive'],
    'Preem Hair (4K) 8223 3.0.0 2026-10-21T01-20Z G5yE5CC3f.zip': ['archive\\pc\\mod\\###-PreemHair.archive'],
    'Reyes Accessories - Main File-17069-1-1-1741904576.zip': ['archive/pc/mod/rm_acc_rings_reyes.archive', 'archive/pc/mod/rm_acc_rings_reyes.xl', 'archive/pc/mod/rm_acc_wrist_reyesbrac.archive', 'archive/pc/mod/rm_acc_wrist_reyesbrac.xl', 'archive/pc/mod/rm_acc_wrist_reyeswatch.archive', 'archive/pc/mod/rm_acc_wrist_reyeswatch.xl', 'r6/tweaks/raem/rm_acc_rings_reyes.yaml', 'r6/tweaks/raem/rm_acc_wrist_reyesbrac.yaml', 'r6/tweaks/raem/rm_acc_wrist_reyeswatch.yaml'],
    "V's Bullet Necklace - Main-15076-1-1-1722784499.zip": ['archive/pc/mod/rm_acc_neck_bulletv.archive', 'archive/pc/mod/rm_acc_neck_bulletv.xl', 'r6/tweaks/raem/rm_acc_neck_bulletv.yaml'],
    'Zenitex Balaclava Pack - Alt. Colors-17411-2-1-1780145354.zip': ['archive/pc/mod/0_scorpion_zenitex_balaclava_pack_addon_alt_colors.archive'],
    'Zenitex Balaclava Pack - GS-17411-2-1-1780145292.zip': ['archive/pc/mod/0_scorpion_zenitex_balaclava_pack_addon_garment_support.archive'],
    'Zenitex Balaclava Pack-17411-2-1-1780145222.zip': ['archive/pc/mod/scorpion_zenitex_balaclava_pack.archive', 'archive/pc/mod/scorpion_zenitex_balaclava_pack.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_zenitex_balaclava_pack.yaml'],
    'Zenitex Combat Goggles-17049-1-4-1757022742.zip': ['archive/pc/mod/scorpion_military_accessories_zenitex_goggles.archive', 'archive/pc/mod/scorpion_military_accessories_zenitex_goggles.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_military_accessories_zenitex_goggles.yaml'],
    'Zenitex Military Backpack-18152-1-5-1757023271.zip': ['archive/pc/mod/scorpion_military_zenitex_backpack.archive', 'archive/pc/mod/scorpion_military_zenitex_backpack.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_military_zenitex_backpack.yaml'],
    'Zenitex Underwear-20394-1-5-1757025183.zip': ['archive/pc/mod/scorpion_military_zenitex_underwear.archive', 'archive/pc/mod/scorpion_military_zenitex_underwear.xl', 'codes.txt', 'r6/tweaks/scorpiontank/scorpion_military_zenitex_underwear.yaml'],
}


# The fifth round (Zenitex Core Dependency, which every Zenitex outfit needs; The Community Palette
# Project, which raem's jewellery needs, a bare .archive at the zip's root; Immersive First Person,
# Katana Pack 2, Browser Extension and Curbside): each download's real file name and entries, read from
# the archive itself (or, for a .rar or .7z, its listing), with the files a rule must pass over.
ROUND5 = {
    'BrowserExtensionExample-10038-0-9-1697377093.7z': ['archive/pc/mod/CustomSiteExample.archive', 'r6/scripts/CustomSiteExample/customSiteExample.reds'],
    'BrowserExtensionFramework-10038-0-9-7-1758341320.7z': ['r6/scripts/BrowserExtension/browserController.overrides.reds', 'r6/scripts/BrowserExtension/BrowserExtension.Classes.reds', 'r6/scripts/BrowserExtension/BrowserExtension.Config.reds', 'r6/scripts/BrowserExtension/BrowserExtension.DataStructures.reds', 'r6/scripts/BrowserExtension/BrowserExtension.System.reds', 'r6/scripts/BrowserExtension/HomePagePagination.reds', 'r6/scripts/BrowserExtension/ModSettingsConditional.reds'],
    'Curbside 1.0 35922 1.0.1 2026-10-27T14-01Z ujWojTTDA.zip': ['r6/scripts/Curbside/CBS_Hooks.reds', 'r6/scripts/Curbside/CBS_Run.reds', 'r6/scripts/Curbside/CBS_Settings.reds', 'r6/scripts/Curbside/CBS_System.reds'],
    'Immersive First Person - ITP Compatibility 2675 2.2.0 2026-10-27T10-12Z 3dwHd99VF.zip': ['archive/pc/mod/0_ImmersiveFirstPerson_ITP_Compat.archive'],
    'Immersive First Person 2675 2.2.0 2026-10-25T14-31Z D2ZS2nnWA.zip': ['bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/init.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/GameSession.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/Vars.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/CameraCore.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/NativeCameraCurve.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/RuntimeHeight.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/Helpers.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/NativeCameraSampler.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/Config.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/Modules/HeightControl.lua', 'red4ext/plugins/ImmersiveFirstPerson/ImmersiveFirstPerson.dll', 'r6/scripts/ImmersiveFirstPerson/References.reds', 'r6/scripts/ImmersiveFirstPerson/LookAt.reds', 'archive/pc/mod/ImmersiveFirstPersonHeight.archive'],
    'Katana Pack 2 36164 1.1 2026-11-07T04-37Z NEnvE30sA.rar': ['archive/pc/mod/Katana_Pack_2.archive', 'archive/pc/mod/Katana_Pack_2.xl', 'r6/audioware/KatanaPack2Sounds/KatanaMortalCharge.wav', 'r6/audioware/KatanaPack2Sounds/KatanaSamurai.yml', 'r6/audioware/KatanaPack2Sounds/KatanaSamuraiCharge.wav', 'r6/audioware/KatanaPack2Sounds/KatanaTanjiroCharge.wav', 'r6/audioware/KatanaPack2Sounds/MortalKatana.yml', 'r6/audioware/KatanaPack2Sounds/Samurai_FireBlast.wav', 'r6/audioware/KatanaPack2Sounds/SwordOfNight.yml', 'r6/audioware/KatanaPack2Sounds/SwordOfNightCharge.wav', 'r6/audioware/KatanaPack2Sounds/TanjiroKatana.yml', 'r6/scripts/KatanaPack2_Scripts/KatanaCyberfang.reds', 'r6/scripts/KatanaPack2_Scripts/KatanaSamurai.reds', 'r6/scripts/KatanaPack2_Scripts/KatanaSamurai_Audio.reds', 'r6/scripts/KatanaPack2_Scripts/MortalKatanaCharge.reds', 'r6/scripts/KatanaPack2_Scripts/MortalKatanaCharge_Audio.reds', 'r6/scripts/KatanaPack2_Scripts/SwordOfNightCharge.reds', 'r6/scripts/KatanaPack2_Scripts/SwordOfNightCharge_Audio.reds', 'r6/scripts/KatanaPack2_Scripts/TanjiroKatanaCharge.reds', 'r6/scripts/KatanaPack2_Scripts/TanjiroKatanaCharge_Audio.reds', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Arasaka_Blade_EX_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Arasaka_Blade_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Black_Noir_Sword_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_AzureSlash_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_BlackMortal_Blade_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_Cyberfang_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_DazzlingBlade_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_GoldenRoses_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_MortalBlade_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_Nagakiba_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_Sakai_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_Samurai_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_Susurrus_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_Synthwave_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_Tanjiro_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Kindjal_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Sword_of_Night_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Arasaka_Blade.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Arasaka_Blade_EX.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Arasaka_Blade_EX_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Arasaka_Blade_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Black_Noir_Sword.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Black_Noir_Sword_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_AzureSlash.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_AzureSlash_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_BlackMortal_Blade.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_BlackMortal_Blade_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Cyberfang.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Cyberfang_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_DazzlingBlade.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_DazzlingBlade_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_GoldenRoses.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_GoldenRoses_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_MortalBlade.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_MortalBlade_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Nagakiba.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Nagakiba_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Sakai.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Sakai_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Samurai.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Samurai_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Susurrus.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Susurrus_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Synthwave.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Synthwave_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Tanjiro.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Tanjiro_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Kindjal.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Kindjal_Recipes.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Sword_of_Night.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Sword_of_Night_Recipes.yaml'],
    'Nagakiba 36164 1.1 2026-11-07T04-36Z JSKWSQsh2.rar': ['archive/pc/mod/Katana_Nagakiba.archive', 'archive/pc/mod/Katana_Nagakiba.xl', 'r6/tweaks/Katana & Sword Pack 2 Iconic/Katana_Nagakiba_Iconic.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Nagakiba.yaml', 'r6/tweaks/Katana & Sword Pack 2 Non_Iconic/Katana_Nagakiba_Recipes.yaml'],
    'The Community Palette Project-10437-1-1-1710101546.zip': ['TheCommunityPaletteProject_MLTemplateResource.archive'],
    'Zenitex Core Dependency - Verdant Set-16356-4-1-3-1766449434.zip': ['archive/pc/mod/!0_scorpion_zenitex_core_dependency_addon_custom_verdant.archive'],
    'Zenitex Core Dependency 16356 5.1.8 2026-08-21T11-39Z JSKWSQkA8.zip': ['archive/pc/mod/#_scorpion_zenitex_core_dependency.archive', 'archive/pc/mod/#_scorpion_zenitex_core_dependency.xl', 'r6/tweaks/scorpiontank/#_scorpion_zenitex_core_dependency.yaml'],
}

ROUND7 = {   # round 7: the chosen files and the decoys their rules pass over (the real archives' game folders)
    'The_Empathy_Club_Unlocked_1.2_2.5 27380 1.2 2026-11-02T19-38Z PYMIYq3re.rar': ['archive/pc/mod/The_Empathy_Club_Unlocked.archive', 'archive/pc/mod/The_Empathy_Club_Unlocked.xl'],
    'The_Empathy_Club_Remastered_1.2 27380 1.2 2026-11-02T19-39Z Co8doe6Tp.rar': ['archive/pc/mod/The_Empathy_Club_Remastered.archive', 'archive/pc/mod/The_Empathy_Club_Remastered.xl'],
    'The_Empathy_Club_No_Bouncers_2.5 27380 1.1 2026-11-02T19-40Z FKtYKrCc4.rar': ['archive/pc/mod/The_Empathy_Club_No_Bouncers_2.5.xl'],
    'The_Empathy_Club_Unlocked_1.1_2.31-27380-1-1-1773437002.zip': ['archive/pc/mod/The_Empathy_Club_Unlocked_1.1.archive', 'archive/pc/mod/The_Empathy_Club_Unlocked_1.1.xl'],
    'Dicky Twister Club Unlocked 1.1 27101 1.1 2026-10-31T23-48Z lcXrcZMX4.rar': ['archive/pc/mod/Dicky_Twister_Club_Unlocked.archive', 'archive/pc/mod/Dicky_Twister_Club_Unlocked.xl'],
    'Dicky Twister Club Unlocked-27101-1-0-1769400942.zip': ['archive/pc/mod/Dicky_Twister_Club_Unlocked_1.0.archive', 'archive/pc/mod/Dicky_Twister_Club_Unlocked_1.0.xl'],
    'Heavy Hearts Club Unlocked _1.3_2.5 27108 1.3 2026-10-29T23-17Z 2w0lw17QS.rar': ['archive/pc/mod/Heavy_Hearts_Club_Unlocked.archive', 'archive/pc/mod/Heavy_Hearts_Club_Unlocked.xl', 'archive/pc/mod/Heavy_Hearts_Club_Unlocked_Removals.xl'],
    'Heavy Hearts Club Unlocked _1.2_2.31-27108-1-2-1770247198.zip': ['archive/pc/mod/Heavy_Hearts_Club_Unlocked_1.0.archive', 'archive/pc/mod/Heavy_Hearts_Club_Unlocked_1.0.xl'],
    'Afterlife Unlocked and Remastered 1.3 27242 1.3 2026-10-29T01-13Z LACBAIvez.rar': ['archive/pc/mod/Afterlife_Unlocked_&_Remastered.archive', 'archive/pc/mod/Afterlife_Unlocked_&_Remastered.xl', 'archive/pc/mod/Afterlife_Unlocked_&_Remastered_Removals.xl'],
    'Afterlife Unlocked and Remastered Doors-27242-1-1-1772578702.zip': ['archive/pc/mod/Afterlife_Unlocked_&_Remastered_Doors_1.1.archive', 'archive/pc/mod/Afterlife_Unlocked_&_Remastered_Doors_1.1.xl'],
    'Heres Brendan 25629 1.1.4 2026-11-02T02-32Z psSjsvmNe.zip': ['archive/pc/mod/HeresBrendan.archive', 'archive/pc/mod/HeresBrendan.xl', 'r6/tweaks/HeresBrendan/heresbrendan.yaml'],
    'NightCityTrafficOverhaul v2.51 (2.31 and 2.5) 25552 2.51 2026-10-27T00-16Z IieOigg7C.rar': ['archive/pc/mod/NightCityTrafficOverhaul.archive', 'r6/scripts/NightCityTrafficOverhaul/NCTO.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOdistrictDB.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOmoddedVehicles.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOsettings.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOvehicleLights.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOvehicles.reds', 'r6/tweaks/NightCityTrafficOverhaul/Aldecados.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Animals.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Arasaka.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Barghest.yaml', 'r6/tweaks/NightCityTrafficOverhaul/KangTao.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Maelstrom.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Militech.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Mox.yaml', 'r6/tweaks/NightCityTrafficOverhaul/NCPD.yaml', 'r6/tweaks/NightCityTrafficOverhaul/NCTOtrafficNCPDVehicles.yaml', 'r6/tweaks/NightCityTrafficOverhaul/NCTOutils.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Scavengers.yaml', 'r6/tweaks/NightCityTrafficOverhaul/SecurityGuards.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Sixthstreet.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Transport.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Tyger.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Utility.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Valentinos.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Voodoo.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Wraith.yaml', 'r6/tweaks/NightCityTrafficOverhaul/YourCustomVehicles.yaml'],
    'NightCityTrafficOverhaul v3.04 (2.31 and 2.5) 25552 3.04 2026-11-08T00-28Z hF7PF4JW4.rar': ['archive/pc/mod/NightCityTrafficOverhaul.archive', 'r6/scripts/NightCityTrafficOverhaul/NCTO.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOdistrictDB.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOexternal.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOgangerVehicleReaction.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOjsonMeta.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOmoddedVehicles.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOprofiles.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOsettings.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOtags.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOtraffic.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOtroubleshoot.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOvehicleLights.reds', 'r6/scripts/NightCityTrafficOverhaul/NCTOvehicles.reds', 'r6/tweaks/NightCityTrafficOverhaul/Afterlife.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Aldecados.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Animals.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Arasaka.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Barghest.yaml', 'r6/tweaks/NightCityTrafficOverhaul/KangTao.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Maelstrom.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Militech.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Mox.yaml', 'r6/tweaks/NightCityTrafficOverhaul/NCPD.yaml', 'r6/tweaks/NightCityTrafficOverhaul/NCTOtrafficNCPDVehicles.yaml', 'r6/tweaks/NightCityTrafficOverhaul/NCTOutils.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Scavengers.yaml', 'r6/tweaks/NightCityTrafficOverhaul/SecurityGuards.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Sixthstreet.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Transport.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Tyger.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Utility.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Valentinos.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Voodoo.yaml', 'r6/tweaks/NightCityTrafficOverhaul/Wraith.yaml', 'r6/tweaks/NightCityTrafficOverhaul/YourCustomVehicles.yaml'],
    'Bike Overhaul - TweakXL - Handling Only-27989-1-0-1772648715.zip': ['r6/tweaks/BikeOverhaul/apollo.yaml', 'r6/tweaks/BikeOverhaul/arch.yaml', 'r6/tweaks/BikeOverhaul/kusanagi.yaml'],
    'ArchV4 - Compatibility-27989-1-1775065863.zip': ['r6/tweaks/ArchV4_Fyrn.tweak', 'r6/tweaks/ArchV4_Fyrn.yaml', 'r6/tweaks/ArchV4_FZR.tweak', 'r6/tweaks/ArchV4_FZR.yaml', 'r6/tweaks/ArchV4_ICONS.tweak', 'r6/tweaks/ArchV4_Malina.tweak', 'r6/tweaks/ArchV4_Malina.yaml', 'r6/tweaks/ArchV4_Mogus.tweak', 'r6/tweaks/ArchV4_Mogus.yaml', 'r6/tweaks/ArchV4_Paladin.tweak', 'r6/tweaks/ArchV4_Paladin.yaml', 'r6/tweaks/ArchV4_Valor.tweak', 'r6/tweaks/ArchV4_Valor.yaml', 'r6/tweaks/ArchV4_Vigil.tweak', 'r6/tweaks/ArchV4_Vigil.yaml'],
    'Oranje3 Edgerunner Emperor-28185-1-0-2-1773399983.zip': ['archive/pc/mod/oranje3_edgerunner_emperor.archive', 'archive/pc/mod/oranje3_edgerunner_emperor.xl', 'r6/tweaks/oranje3_edgerunner_emperor/oranje3_edgerunner_emperor.yaml'],
    'Toyota Supra Mk3-27955-1-1-1775609966.zip': ['archive/pc/mod/CORNMILF_Toyota_Supra_A70.archive', 'archive/pc/mod/toyota_supra_a70.xl', 'r6/scripts/cornmilf_cars/supra_a70_pop_up.reds', 'r6/tweaks/cornmilf/toyota_supra_a70.tweak', 'r6/tweaks/cornmilf/toyota_supra_a70_ICONS.tweak'],
    'Polestar 1 Hero Edition-26891-1-1-1768644855.zip': ['archive/pc/mod/aabdii_polestar_1_hero.xl', 'archive/pc/mod/polestar_1_hero_original.archive', 'r6/tweaks/polestar_hero/aabdii_polestar_1_hero.yaml'],
    'Spoiler delete patch-26891-1-0-1768596314.zip': ['archive/pc/mod/!_polestar_1_no_spoiler_patch.archive'],
    'FPP Speedometer 26156 1.3.0 2026-09-06T04-45Z OCk3C5kDR.zip': ['r6/scripts/FPPSpeedometer/FPPSpeedometer.reds', 'r6/input/fpp_speedometer.xml'],
    'Clear Skill Checks-2805-1-1-1-1764416716.zip': ['r6/config/redsUserHints/clear_skill_checks.toml', 'r6/scripts/clear_skill_checks.reds'],
    'Filter Saves 3400 1.7.1 2026-10-28T20-58Z rxs7xRela.zip': ['archive/pc/mod/FilterSaves.archive', 'archive/pc/mod/FilterSaves.archive.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/FilterSaves/GameUI.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/FilterSaves/init.lua', 'r6/config/redsUserHints/filter_saves.toml', 'r6/scripts/filter_saves.reds'],
    'Loot Icons Extension Light 16386 1.60 2026-10-27T06-36Z D2ZS2nnCn.zip': ['archive/pc/mod/LootIconsExtension.archive.xl', 'archive/pc/mod/LootIconsExtensionLight.archive', 'r6/scripts/LootIconsExtension/LootIconsExtension.reds', 'r6/scripts/LootIconsExtension/LootIconsExtension_tints.reds', 'r6/scripts/LootIconsExtension/LootIconsExtension_yml.reds'],
    'Loot Icons Extension 16386 1.60 2026-11-01T19-36Z PYMIYq31p.zip': ['archive/pc/mod/LootIconsExtension.archive', 'archive/pc/mod/LootIconsExtension.archive.xl', 'r6/scripts/LootIconsExtension/LootIconsExtension.reds', 'r6/scripts/LootIconsExtension/LootIconsExtensionFix.reds', 'r6/scripts/LootIconsExtension/LootIconsExtension_tints.reds', 'r6/scripts/LootIconsExtension/LootIconsExtension_yml.reds', 'red4ext/plugins/loot_icons_extension_fix/checksum.txt', 'red4ext/plugins/loot_icons_extension_fix/loot_icons_extension_fix.dll'],
    'Unified Mod Settings 28308 2.8 2026-11-05T22-11Z D2ZS2n3fm.rar': ['bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/init.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/lib/Cron.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/lib/EventProxy.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/lib/Ref.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/LICENSE', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/browserOrganization.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/callbackRouter.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/dataAggregator.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/favorites.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/localizer.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/logger.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/managedStartup.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/menuAccess.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/menuHotkey.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/menuResume.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/modPreviewCompat.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/openProfiler.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/palette.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/profileExclusions.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/profilePolicy.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/profilePopup.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/profiles.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/profileState.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/quickslotsCompat.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/search.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/suppression.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/umsConfig.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/modules/umsRenderer.lua', 'r6/scripts/UnifiedModSettings/ButtonHintsHelper.reds', 'r6/scripts/UnifiedModSettings/Localization/LocalizationProvider.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Arabic.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/BrazilianPortuguese.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/ChineseSimplified.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/ChineseTraditional.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Czech.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/English.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/French.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/German.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Hungarian.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Italian.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Japanese.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Korean.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/LatinAmericanSpanish.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Polish.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Russian.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Spanish.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Thai.reds', 'r6/scripts/UnifiedModSettings/Localization/Packages/Turkish.reds', 'r6/scripts/UnifiedModSettings/SearchInput.reds', 'r6/scripts/UnifiedModSettings/suppression.reds', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/browserLayouts', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/profileHistory', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/profiles', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/profileState', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/profileTransfers', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/profileTrash', 'bin/x64/plugins/cyber_engine_tweaks/mods/UnifiedModSettings/userProfiles'],
    'Fluff Vendor Fixes 27795 1.1.2 2026-10-09T21-13Z 6ZNKZczf8.zip': ['r6/scripts/FluffVendorFixes/FluffVendorFixes.reds', 'r6/tweaks/FluffVendorFixes/FluffVendorFixes.yaml'],
    'Street Vendors - Only Drinks-27795-1-0-1-1772228586.zip': ['r6/scripts/FluffVendorFixes/FluffVendorFixes.reds', 'r6/tweaks/FluffVendorFixes/FluffVendorFixes.yaml'],
    'Dusty_MaxTacSuit-26517-1-0-1766844711.zip': ['archive/pc/mod/Dusty_MaxTacSuit.archive', 'archive/pc/mod/Dusty_MaxTacSuit_F.xl', 'archive/pc/mod/Dusty_MaxTacSuit_M.xl', 'r6/tweaks/Dusty/Dusty_MaxTacSuit_F.yaml', 'r6/tweaks/Dusty/Dusty_MaxTacSuit_M.yaml'],
    'Prestige glasses-27118-1-11-1774008492.zip': ['r6/tweaks/prestigeglasses.yaml', 'archive/pc/mod/prestigeglasses.archive', 'archive/pc/mod/prestigeglasses.archive.xl'],
    'Nike x Off-White - Jordan 1 Euro-27597-1-12-0-1772669638.zip': ['r6/tweaks/drc_nike_airjordan_euro.yaml', 'archive/pc/mod/DrCatherwood_Nike_AirJordan_Euro.archive', 'archive/pc/mod/drc_nike_airjordan_euro.archive.xl'],
    "Catherwood's - Virtual Atelier Shop-27599-1-0-2-1772679408.zip": ['archive/pc/mod/DrCatherwoodAtelier.archive', 'r6/scripts/drcatherwood/drcatherwoodatelier-atelier-store.reds'],
    'Beautiful Exotics Eyes CCXL by protossvoid-25718-1-0-1763438951.zip': ['archive/pc/mod/BeautifulExoticsCCXL.archive', 'archive/pc/mod/protoss_BeautifulExoticsCCXL.xl', 'r6/tweaks/protoss/protoss_BeautifulExoticsCCXL.yaml'],
    'Beautiful Exotics CCXL - NO EYE HIGHLIGHTS version 25718 1 2026-09-20T20-15Z sHlUHDlLh.zip': ['archive/pc/mod/BeautifulExoticsNoHighlightsCCXL.archive', 'archive/pc/mod/protoss_BeautifulExoticsNoHighlightsCCXL.xl', 'r6/tweaks/protoss/protoss_BeautifulExoticsNoHighlightsCCXL.yaml'],
}

ROUND9 = {   # round 9: hair, makeup, eyes, menus, combat, crowds, places and a car; the chosen files and the decoys
    # their rules pass over (the real archives' game folders, from Nexus Mods' file previews and the downloads;
    # a decoy without a preview holds what its main file holds)
    'Parking Spots Enhanced 15708 1.2.5 2026-10-27T02-39Z sHlUHDDFc.zip': ['archive/pc/mod/#MotelParkingFix.archive', 'archive/pc/mod/ParkingSpotsEnhanced.archive', 'archive/pc/mod/ParkingSpotsEnhanced.archive.xl'],
    'Parking Spots Enhanced (alt)-15708-1-2-2-1737669496.zip': ['archive/pc/mod/#MotelParkingFix.archive', 'archive/pc/mod/ParkingSpotsEnhanced.archive.xl', 'archive/pc/mod/ParkingSpotsEnhancedAlt.archive'],
    'NPC Vehicle Reactions Fixed-19530-1-0-0-1738530015.zip': ['r6/tweaks/NPCVehicleReactionsFixed/NPCVehicleReactionsFixed.yaml'],
    'Always First Equip 2557 2.2.0 2026-10-24T19-15Z mPgaPVVHG.zip': ['archive/pc/mod/AlwaysFirstEquip.archive', 'archive/pc/mod/AlwaysFirstEquip.archive.xl', 'r6/input/AlwaysFirstEquip.xml', 'r6/scripts/alwaysFirstEquip.reds'],
    'Translation sources-2557-1-9-1649261666.zip': ['r6/scripts/alwaysFirstEquip.reds'],
    'Disable ONLY 2D Effect For UI And Disable Chrom Ab-2648-2-00-1695865650.rar': ['archive/pc/mod/_Disable ONLY 2D Effect For UI And Disable Chrom Ab.archive'],
    'Disable ONLY 2D Effect For UI And Keep Vanilla Chr-2648-2-00-1695865733.rar': ['archive/pc/mod/_Disable ONLY 2D Effect For UI And Keep Vanilla Chrom Ab.archive'],
    'Updo Hair Collection - ALL-IN-ONE 26834 1.4 2026-06-28T17-26Z G5yE5CJPT.rar': ['RVLL_CCXL_Bel_Air_Updo.archive', 'RVLL_CCXL_Bel_Air_Updo.xl', 'RVLL_CCXL_Chevelle_Updo.archive', 'RVLL_CCXL_Chevelle_Updo.xl', 'RVLL_CCXL_Corvette_Updo.archive', 'RVLL_CCXL_Corvette_Updo.xl', 'RVLL_CCXL_Daytona_Updo.archive', 'RVLL_CCXL_Daytona_Updo.xl', 'RVLL_CCXL_Skylark_Updo.archive', 'RVLL_CCXL_Skylark_Updo.xl'],
    'Updo Hair Collection - CHEVELLE-26834-1-3-1775654189.zip': ['archive/pc/mod/RVLL_CCXL_Chevelle_Updo.archive', 'archive/pc/mod/RVLL_CCXL_Chevelle_Updo.xl'],
    'MAKE UP - ENHANCER - 256x256 pixels-28869-1-1776522599.zip': ['archive/pc/mod/!_Arkhe_MAKEUP_Enhancer.archive'],
    'MAKE UP - ENHANCER - 64x64 pixels-28869-1-1776522895.zip': ['archive/pc/mod/!_Arkhe_MAKEUP_Enhancer.archive'],
    'Beautiful MAKEUP - BASE-29336-1-1777732105.zip': ['archive/pc/mod/Arkhe_Beautiful_Makeup_Base_CCXL.archive', 'archive/pc/mod/Arkhe_Beautiful_Makeup_Base_CCXL.xl'],
    'Beautiful MAKEUP - BASE-29336-2-1777855886.zip': ['archive/pc/mod/Arkhe_Beautiful_Makeup_Base_CCXL.archive', 'archive/pc/mod/Arkhe_Beautiful_Makeup_Base_CCXL.xl'],
    'Beautiful MAKEUP II - BASE - Basegame Head-29513-1-1778297809.zip': ['archive/pc/mod/Arkhe_Beautiful_Makeup_02_Base_CCXL.archive', 'archive/pc/mod/Arkhe_Beautiful_Makeup_02_Base_CCXL.xl'],
    'Beautiful MAKEUP II - BASE - EKT and Custom Head-29513-1-1778297767.zip': ['archive/pc/mod/Arkhe_Beautiful_Makeup_02_Base_CCXL.archive', 'archive/pc/mod/Arkhe_Beautiful_Makeup_02_Base_CCXL.xl'],
    'ZXR CCXL Himiko Hair Buns 34688 1 2026-10-04T23-13Z bWY8WhEcA.zip': ['archive/pc/mod/ZXR - AXL Hair - Himiko Hair Bangs.xl', 'archive/pc/mod/ZXR - CCXL Hair - Himiko Buns.xl', 'archive/pc/mod/ZXR_-_CCXL_-_Himiko_Hair_Buns.archive', 'r6/tweaks/Zwei x Rev/ZXR - AXL Hair - Himiko Bangs.yaml'],
    'Mecha Robotic Eyes CCXL by protossvoid 35373 1 2026-10-17T02-19Z tvQTvssii.zip': ['archive/pc/mod/MechaRoboticEyesCCXL.archive', 'archive/pc/mod/protoss_MechaRoboticEyesCCXL.xl', 'r6/tweaks/protoss/protoss_MechaRoboticEyesCCXL.yaml'],
    'Atomiic Soft Blunt Bob Hair CCXL 35463 1 2026-10-19T03-43Z ujWojTTQO.zip': ['archive/pc/mod/Atomiic_Soft_Blunt_Bob_Hair_CCXL.archive', 'archive/pc/mod/atomiic_softbluntbob_ccxl.xl'],
    'Atomiic Violet Hair CCXL 35739 1 2026-10-24T09-11Z mPgaPVV69.zip': ['archive/pc/mod/Atomiic_Violet_Hair_CCXL.archive', 'archive/pc/mod/atomiic_violet_hair_ccxl.xl'],
    'Mecha Robotic Eyes Part2 CCXL by protossvoid 35807 1 2026-10-25T00-58Z 5em9eoood.zip': ['archive/pc/mod/MechaRoboticEyesPart2CCXL.archive', 'archive/pc/mod/protoss_MechaRoboticEyesPart2CCXL.xl', 'r6/tweaks/protoss/protoss_MechaRoboticEyesPart2CCXL.yaml'],
    'Modded Save Loading Screen Fix 35867 1.0.1 2026-11-01T08-57Z 2w0lw177f.zip': ['r6/scripts/Modded Save Loading Screen Fix/Modded Save Loading Screen Fix.reds'],
    'No Load Popups 35867 1.0.0 2026-10-25T16-20Z MTheTjjFN.zip': ['r6/scripts/Modded Save Loading Screen Fix/Modded Save Loading Screen Fix - No Load Popups.reds'],
    'StealthFixes 35951 1.0.1 2026-11-01T22-41Z Q6xF6licx.zip': ['r6/scripts/StealthFixes/StealthFixesCrouch.reds', 'r6/scripts/StealthFixes/StealthFixesFinisherRagdoll.reds', 'r6/scripts/StealthFixes/StealthFixesRemoteCar.reds'],
    'CCXL - XYLA 36246 1 2026-10-28T00-10Z FKtYKrrFx.zip': ['archive/pc/mod/MELUMINARY - CCXL - XYLA SHAG MULLET.archive', 'archive/pc/mod/MELUMINARY - CCXL - XYLA SHAG MULLET.xl'],
    'Atomiic Yumeko Hair CCXL 36291 1 2026-10-28T13-57Z bWY8WhBWx.zip': ['archive/pc/mod/Atomiic_Yumeko_Hair_CCXL.archive', 'archive/pc/mod/atomiic_yumeko_hair_ccxl.xl'],
    'ApexGrapple 1.0.7 36443 1.0.7 2026-11-02T23-33Z LACBAIvh4.zip': ['r6/scripts/ApexGrapple/Aim.reds', 'r6/scripts/ApexGrapple/Arm.reds', 'r6/scripts/ApexGrapple/Fall.reds', 'r6/scripts/ApexGrapple/FallEffect.reds', 'r6/scripts/ApexGrapple/Frame.reds', 'r6/scripts/ApexGrapple/Ground.reds', 'r6/scripts/ApexGrapple/Hit.reds', 'r6/scripts/ApexGrapple/Hook.reds', 'r6/scripts/ApexGrapple/HookTiming.reds', 'r6/scripts/ApexGrapple/Implant.reds', 'r6/scripts/ApexGrapple/Jump.reds', 'r6/scripts/ApexGrapple/Key.reds', 'r6/scripts/ApexGrapple/KeyBindings.reds', 'r6/scripts/ApexGrapple/KeyProfile.reds', 'r6/scripts/ApexGrapple/Ladder.reds', 'r6/scripts/ApexGrapple/LadderExit.reds', 'r6/scripts/ApexGrapple/Landing.reds', 'r6/scripts/ApexGrapple/Launcher.reds', 'r6/scripts/ApexGrapple/LauncherCrosshair.reds', 'r6/scripts/ApexGrapple/LauncherHand.reds', 'r6/scripts/ApexGrapple/LauncherRope.reds', 'r6/scripts/ApexGrapple/LauncherWatch.reds', 'r6/scripts/ApexGrapple/Localization.reds', 'r6/scripts/ApexGrapple/LocalizationChinese.reds', 'r6/scripts/ApexGrapple/Log.reds', 'r6/scripts/ApexGrapple/OwnKey.reds', 'r6/scripts/ApexGrapple/Pieces.reds', 'r6/scripts/ApexGrapple/PiecesData.reds', 'r6/scripts/ApexGrapple/PiecesDraw.reds', 'r6/scripts/ApexGrapple/Prerequisites.reds', 'r6/scripts/ApexGrapple/Profile2.reds', 'r6/scripts/ApexGrapple/Profile3.reds', 'r6/scripts/ApexGrapple/Profile4.reds', 'r6/scripts/ApexGrapple/Profile5.reds', 'r6/scripts/ApexGrapple/Profiles.reds', 'r6/scripts/ApexGrapple/Pull.reds', 'r6/scripts/ApexGrapple/Pulling.reds', 'r6/scripts/ApexGrapple/Push.reds', 'r6/scripts/ApexGrapple/QuickMelee.reds', 'r6/scripts/ApexGrapple/Release.reds', 'r6/scripts/ApexGrapple/RightWeapon.reds', 'r6/scripts/ApexGrapple/RopeBends.reds', 'r6/scripts/ApexGrapple/RopeHang.reds', 'r6/scripts/ApexGrapple/RopeLead.reds', 'r6/scripts/ApexGrapple/RopeMotion.reds', 'r6/scripts/ApexGrapple/RopeShape.reds', 'r6/scripts/ApexGrapple/RopeStart.reds', 'r6/scripts/ApexGrapple/Settings.reds', 'r6/scripts/ApexGrapple/Shot.reds', 'r6/scripts/ApexGrapple/Sounds.reds', 'r6/scripts/ApexGrapple/TakenOver.reds', 'r6/scripts/ApexGrapple/Target.reds', 'r6/scripts/ApexGrapple/View.reds', 'r6/scripts/ApexGrapple/Wrist.reds', 'r6/scripts/ApexGrapple/Yank.reds', 'r6/scripts/ApexGrapple/YankFlight.reds', 'r6/scripts/ApexGrapple/YankFrame.reds', 'r6/scripts/ApexGrapple/YankSeen.reds', 'r6/scripts/ApexGrapple/YankShield.reds', 'r6/scripts/ApexGrapple/YankSteer.reds', 'r6/scripts/ApexGrapple/YankWatch.reds', 'r6/scripts/ApexGrapple/YankWhy.reds', 'r6/tweaks/ApexGrapple/speed_cap.yaml', 'archive/pc/mod/ApexGrapple.archive'],
    'ApexGrapple 1.0.7 For v2.31 Kobat 36443 1.0.7 2026-11-06T23-42Z mPgaPVbUD.zip': ['r6/scripts/ApexGrapple/Aim.reds', 'r6/scripts/ApexGrapple/Arm.reds', 'r6/scripts/ApexGrapple/Fall.reds', 'r6/scripts/ApexGrapple/FallEffect.reds', 'r6/scripts/ApexGrapple/Frame.reds', 'r6/scripts/ApexGrapple/Ground.reds', 'r6/scripts/ApexGrapple/Hit.reds', 'r6/scripts/ApexGrapple/Hook.reds', 'r6/scripts/ApexGrapple/HookTiming.reds', 'r6/scripts/ApexGrapple/Implant.reds', 'r6/scripts/ApexGrapple/Jump.reds', 'r6/scripts/ApexGrapple/Key.reds', 'r6/scripts/ApexGrapple/KeyBindings.reds', 'r6/scripts/ApexGrapple/KeyProfile.reds', 'r6/scripts/ApexGrapple/Ladder.reds', 'r6/scripts/ApexGrapple/LadderExit.reds', 'r6/scripts/ApexGrapple/Landing.reds', 'r6/scripts/ApexGrapple/Launcher.reds', 'r6/scripts/ApexGrapple/LauncherCrosshair.reds', 'r6/scripts/ApexGrapple/LauncherHand.reds', 'r6/scripts/ApexGrapple/LauncherRope.reds', 'r6/scripts/ApexGrapple/LauncherWatch.reds', 'r6/scripts/ApexGrapple/Localization.reds', 'r6/scripts/ApexGrapple/LocalizationChinese.reds', 'r6/scripts/ApexGrapple/Log.reds', 'r6/scripts/ApexGrapple/OwnKey.reds', 'r6/scripts/ApexGrapple/Pieces.reds', 'r6/scripts/ApexGrapple/PiecesData.reds', 'r6/scripts/ApexGrapple/PiecesDraw.reds', 'r6/scripts/ApexGrapple/Prerequisites.reds', 'r6/scripts/ApexGrapple/Profile2.reds', 'r6/scripts/ApexGrapple/Profile3.reds', 'r6/scripts/ApexGrapple/Profile4.reds', 'r6/scripts/ApexGrapple/Profile5.reds', 'r6/scripts/ApexGrapple/Profiles.reds', 'r6/scripts/ApexGrapple/Pull.reds', 'r6/scripts/ApexGrapple/Pulling.reds', 'r6/scripts/ApexGrapple/Push.reds', 'r6/scripts/ApexGrapple/QuickMelee.reds', 'r6/scripts/ApexGrapple/Release.reds', 'r6/scripts/ApexGrapple/RightWeapon.reds', 'r6/scripts/ApexGrapple/RopeBends.reds', 'r6/scripts/ApexGrapple/RopeHang.reds', 'r6/scripts/ApexGrapple/RopeLead.reds', 'r6/scripts/ApexGrapple/RopeMotion.reds', 'r6/scripts/ApexGrapple/RopeShape.reds', 'r6/scripts/ApexGrapple/RopeStart.reds', 'r6/scripts/ApexGrapple/Settings.reds', 'r6/scripts/ApexGrapple/Shot.reds', 'r6/scripts/ApexGrapple/Sounds.reds', 'r6/scripts/ApexGrapple/TakenOver.reds', 'r6/scripts/ApexGrapple/Target.reds', 'r6/scripts/ApexGrapple/View.reds', 'r6/scripts/ApexGrapple/Wrist.reds', 'r6/scripts/ApexGrapple/Yank.reds', 'r6/scripts/ApexGrapple/YankFlight.reds', 'r6/scripts/ApexGrapple/YankFrame.reds', 'r6/scripts/ApexGrapple/YankSeen.reds', 'r6/scripts/ApexGrapple/YankShield.reds', 'r6/scripts/ApexGrapple/YankSteer.reds', 'r6/scripts/ApexGrapple/YankWatch.reds', 'r6/scripts/ApexGrapple/YankWhy.reds', 'r6/tweaks/ApexGrapple/speed_cap.yaml', 'archive/pc/mod/ApexGrapple.archive'],
    'Crowd Voice Unlocked 36527 1.1.0 2026-11-01T15-30Z lcXrcZMqy.zip': ['archive/pc/mod/CrowdVoiceUnlocked.archive', 'r6/scripts/Crowd Voice Unlocked/CrowdLinesFollow.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdLinesIdle.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdLinesIdleData.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdLinesPhone.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdLinesPhoneData.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdLinesPhoneGate.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdLinesPhoneWatch.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdLinesTalk.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdVoiceNaked.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdVoicesRestored.reds', 'r6/scripts/Crowd Voice Unlocked/CrowdVoicesRestoredData.reds'],
    'Dual Wielding Fix 1.0.0 36738 1.0.1 2026-11-03T12-47Z HncQn2Ysm.zip': ['r6/tweaks/DualWieldingFix.yaml', 'r6/scripts/DualWieldingFix/DualWieldingFix.reds'],
    'Geralt of Rivia CCXL Hair 36769 1 2026-11-01T01-22Z sHlUHDPia.zip': ['archive/pc/mod/_0_Vesna_HoV_HAIR_MV_Geralt_CCXL.archive', 'archive/pc/mod/_0_Vesna_HoV_HAIR_MV_Geralt_CCXL.archive.xl'],
    'Silent Silencers and Throwing Knives 4070 1.6.3 2026-10-25T13-01Z sHlUHDDNC.zip': ['archive/pc/mod/SilentSilencers.archive', 'archive/pc/mod/SilentSilencers.archive.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/SilentSilencersAndKnives/GameSettings.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/SilentSilencersAndKnives/GameUI.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/SilentSilencersAndKnives/init.lua', 'r6/config/redsUserHints/SilentSilencersAndKnives.toml', 'r6/scripts/SilentSilencersAndKnives.reds', 'r6/tweaks/silent_silencers.yaml'],
    'Mark To Sell 4725 2.5.5 2026-10-26T15-44Z LACBAIIcT.zip': ['r6/input/MarkToSell.xml', 'r6/scripts/MarkToSell/Config.reds', 'r6/scripts/MarkToSell/Texts.reds', 'r6/scripts/MarkToSell/core/AddFields.reds', 'r6/scripts/MarkToSell/core/CustomIcon.reds', 'r6/scripts/MarkToSell/core/ExtendJunkFilter.reds', 'r6/scripts/MarkToSell/core/HandleUserInput.reds', 'r6/scripts/MarkToSell/core/MarkToSellSystem.reds', 'r6/scripts/MarkToSell/core/VendorScreenTweaks.reds', 'r6/scripts/MarkToSell/helpers/InventoryDataManager.reds'],
    'Immersive Rippers 7064 2.6.2 2026-10-28T21-29Z hF7PF4OLs.zip': ['archive/pc/mod/ImmersiveRippers.archive', 'archive/pc/mod/ImmersiveRippers.archive.xl', 'r6/scripts/ImmersiveRippers/ImmersiveRippers.reds'],
    'Immersive Bartenders-7203-2-0-3-1752967023.zip': ['archive/pc/mod/ImmersiveBartenders.archive'],
    'Sit Anywhere 1.4-7299-1-4-1762025971.zip': ['archive/pc/mod/sitAnywhere.archive', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/config/config.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/init.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/config.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/external/Cron.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/external/GameUI.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/interactionUI.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/logger.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/logic.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/settingsUI.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/utils.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/workspotUtils.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/workspots/benchWorkspot.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/workspots/couchWorkspot.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/workspots/sitWorkspot.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/modules/worldInteraction.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/tween/LICENSE.txt', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/tween/tween.lua'],
    'No Crowd panic from devices redscript 1.2.0-7353-1-2-0-1676631216.zip': ['r6/scripts/No Crowd panic from devices/no_crowd_panic_from_devices.reds'],
    'No Crowd panic from devices CET 1.2.0-7353-1-2-0-1676631159.zip': ['bin/x64/plugins/cyber_engine_tweaks/mods/No Crowd panic from devices/init.lua'],
    'Nissan 240SX-8730-1-32-1702907275.rar': ['archive/pc/mod/nissan_240sx.xl', 'archive/pc/mod/nissan_240sx_main.archive', 'r6/tweaks/nissan_240sx.yaml'],
    'Nissan 240SX-8730-1-31-1696385785.rar': ['archive/pc/mod/nissan_240sx.xl', 'archive/pc/mod/nissan_240sx_main.archive', 'r6/tweaks/nissan_240sx.yaml'],
    'ResetAttributesAlwaysAvailable 9240 1.0.0.7 2026-11-06T00-20Z LACBAImVM.zip': ['r6/scripts/ResetAttributesAlwaysAvailable.reds'],
    'ZKV_StealthFinishers_v2.1.0-9360-2-1-0-1758398350.zip': ['bin/x64/plugins/cyber_engine_tweaks/mods/ZKVTakedowns2/init.lua', 'r6/scripts/ZKVTakedowns2/ZKV_StealthFinishers.reds', 'r6/scripts/ZKVTakedowns2/ZKV_Takedowns_Utils.reds'],
}
ROUND10 = {   # round 10: fixes, tooltips, the wanted HUD, scopes and apartment cats; the chosen files and the decoys their
    # rules pass over (the real archives' game folders, from Nexus Mods' file previews and the downloads)
    'AccidentalFastTravelBugFix 36600 1.0.0.0 2026-10-30T22-20Z VquAqYExL.zip': ['r6/scripts/AccidentalFastTravelBugFix.reds'],
    'Mantis Blades Aerial Takedown Fix - Lethal 34044 1.0.1 2026-09-18T16-37Z MTheTjhQw.zip': ['r6/scripts/Mantis Blades Aerial Takedown Fix/Mantis Blades Aerial Takedown Fix.reds'],
    'Gorilla Arms Aerial Takedown Fix - Lethal 34044 1.0.1 2026-09-18T16-36Z 5em9eomho.zip': ['r6/scripts/Gorilla Arms Aerial Takedown Fix/Gorilla Arms Aerial Takedown Fix.reds'],
    'Mantis Blades Aerial Takedown Fix - Non Lethal 34044 1.0.0 2026-09-18T04-08Z gMz5MuzG3.zip': ['r6/scripts/Mantis Blades Aerial Takedown Fix/Mantis Blades Aerial Takedown Fix.reds'],
    'Bare Hands Aerial Takedown Bloodless 34044 1.0.0 2026-09-18T04-09Z E91D9d1vL.zip': ['r6/scripts/Bare Hand Aerial Takedown Bloodless/Bare Hand Aerial Takedown Bloodless.reds'],
    'Cutscene Weapon Swapper 20743 1.4.2 2026-10-29T17-33Z 8ViLVPN0Z.zip': ['r6/scripts/CutsceneWeaponSwapper.reds'],
    'Deceptious Bug Fixes 18318 1.4.3 2026-10-28T12-16Z psSjsvmAt.zip': ['archive/pc/mod/#DeceptiousBugFixes.archive', 'archive/pc/mod/#DeceptiousBugFixes.archive.xl', 'r6/scripts/#DeceptiousBugFixes/DeceptiousBugFixes.reds', 'r6/tweaks/#DeceptiousBugFixes/DeceptiousBugFixes.yaml'],
    'Better Armor Tooltip-9706-1-0-1-1766882622.zip': ['archive/pc/mod/BetterArmorTooltip.archive', 'archive/pc/mod/BetterArmorTooltip.archive.xl', 'r6/scripts/BetterArmorTooltip.reds'],
    'Cyberware Screen Tooltip Fix-23615-1-0-1755606888.zip': ['r6/scripts/CyberwareScreenTooltipFix.reds'],
    'dynamic_wanted_stars_v1.0-15449-1-0-1719182074.zip': ['archive/pc/mod/dynamic_wanted_stars.archive', 'r6/scripts/dynamic_wanted_stars/DynamicWantedStars.reds'],
    'Preem Scopes-10021-0-17-2-1744383914.zip': ['archive/pc/mod/PreemScopes.archive'],
    'Preem Scopes - Smart Weapons-10021-1-0-0-1697849885.zip': ['archive/pc/mod/PreemScopes-Smart.archive'],
    'Preem Scopes - Binoculars-10021-1-0-1b-1701895039.zip': ['archive/pc/mod/PreemScopes-Binoculars.archive'],
    'Preem Scopes - Binoculars with Frame-10021-1-2-0b-1701900168.zip': ['archive/pc/mod/PreemScopes-Binoculars.archive'],
    'Preem Scope - Militech Holosight Compat-10021-1-0-0-1697516068.zip': ['archive/pc/mod/PreemScopes-MHCompat.archive'],
    'Preem Scope - FOMOD-10021-1-0-0-1702240531.zip': ['fomod/ModuleConfig.xml', 'Preem Scopes/archive/pc/mod/#PreemScopes.archive', 'Smart Weapons/archive/pc/mod/PreemScopes-Smart.archive'],
    'Preem Scopes - No Scope Crosshairs-10021-1-0-0n-1703195684.zip': ['archive/pc/mod/##PreemScopes-NoScopeCrosshairs.archive'],
    'Apartment Cats - Corpo Plaza 6329 3.0.0 2026-09-10T01-25Z 6ZNKZcNIY.zip': ['archive/pc/mod/#CorpoCat.archive', 'archive/pc/mod/CorpoCat.archive.xl', 'r6/tweaks/CorpoCat_Red.yaml'],
    'Apartment Cats - Corpo Plaza Colour Variants-6329-1-2-1671631109.zip': ['CorpoCat_Blue.yaml', 'CorpoCat_Green.yaml', 'CorpoCat_NonHolo.yaml', 'CorpoCat_Red.yaml', 'CorpoCat_White.yaml'],
    'Apartment Cats - Japantown 6493 3.0.1 2026-09-10T01-22Z KRvfRxvOv.zip': ['archive/pc/mod/#JapanCat.archive', 'archive/pc/mod/JapanCat.archive.xl', 'r6/tweaks/JapanCat.yaml'],
    'Apartment Cats - Northside Motel 6379 3.0.0 2026-09-10T19-17Z AgoGgioru.zip': ['archive/pc/mod/#MotelCat.archive', 'archive/pc/mod/MotelCat.archive.xl', 'r6/tweaks/MotelCat.yaml'],
    'Apartment Cats - The Glen 6276 3.0.1 2026-09-10T01-21Z LACBAIC7r.zip': ['archive/pc/mod/#LoftCat.archive', 'archive/pc/mod/LoftCat.archive.xl', 'r6/tweaks/LoftCat.yaml'],
    'Apartment Cats - Dogtown 10325 2.0.0 2026-09-10T19-17Z lcXrcZX8T.zip': ['archive/pc/mod/DogtownCat.archive', 'archive/pc/mod/DogtownCat.archive.xl', 'r6/tweaks/DogtownCat.yaml'],
    'Apartment Cats Customs - Base files-6837-1-3-0-1740786536.zip': ['archive/pc/mod/#ApartmentCatsCustoms_Base.archive', 'archive/pc/mod/#ApartmentCatsCustoms_Corpo_BlackAndWhite.archive', 'archive/pc/mod/#ApartmentCatsCustoms_Dogtown_Black.archive', 'archive/pc/mod/#ApartmentCatsCustoms_Glen_GreyTiger.archive', 'archive/pc/mod/#ApartmentCatsCustoms_Japan_OrangeTiger.archive', 'archive/pc/mod/#ApartmentCatsCustoms_Motel_OrangeWhite.archive'],
    'Apartment Cats Customs - Base files - 4k replacer-6837-1-3-0-1740786473.zip': ['archive/pc/mod/#ApartmentCatsCustoms_Base.archive'],
    'Apartment Cats Customs - Motel Apartment variants-6837-1-3-0-1740786652.zip': ['#ApartmentCatsCustoms_Motel_BlackAndWhite.archive', '#ApartmentCatsCustoms_Motel_GreyTiger.archive', '#ApartmentCatsCustoms_Motel_Black.archive', '#ApartmentCatsCustoms_Motel_WhiteOrange.archive', '#ApartmentCatsCustoms_Motel_OrangeWhite.archive', '#ApartmentCatsCustoms_Motel_White.archive', '#ApartmentCatsCustoms_Motel_OrangeTiger.archive'],
}
ROUND11 = {   # round 11: gameplay fixes and quest fixes; the chosen files and the decoys their rules pass over (the real
    # archives' game folders, from Nexus Mods' file previews and the downloads)
    'Dash Fix 16272 1.0.1 2026-10-25T18-27Z Q6xF6llzo.zip': ['archive/pc/mod/DashFix.archive', 'archive/pc/mod/DashFix.archive.xl', 'r6/scripts/DashFix/DashFix.reds'],
    'Dash Fix-16272-1-0-0-1723844109.zip': ['archive/pc/mod/DashFix.archive', 'archive/pc/mod/DashFix.archive.xl', 'r6/scripts/DashFix/DashFix.reds'],
    "Don't Hide Stamina Bar on Holster-9448-1-0-1696167242.zip": ['r6/scripts/HolsterStaminaBarBugFix.reds'],
    'Easier Controller Sprint 26610 1.1.1 2026-10-25T14-32Z 5em9eooDJ.zip': ['r6/scripts/EasierControllerSprint.reds', 'r6/tweaks/easier_controller_sprint.yaml'],
    'Easier Controller Sprint-26610-1-1-0-1767608356.zip': ['r6/scripts/EasierControllerSprint.reds', 'r6/tweaks/easier_controller_sprint.yaml'],
    'Dodging Fix-17923-0-11-1732072487.rar': ['r6/scripts/DodgesFix.reds'],
    'Eye In The Sky Highlight Fix-30246-1-1780560206.zip': ['r6/scripts/Eye In The Sky Highlight Fix.reds'],
    'Melee Finisher Camera Fix 32173 1 2026-08-02T06-22Z AgoGgimLJ.zip': ['r6/scripts/Melee Finisher Camera Fix/MeleeFinisherCameraFix.reds'],
    'Cyberpunk Story Quest Fixes 29152 1.21.2 2026-11-07T12-58Z 8ViLVPzrd.zip': ['archive/pc/mod/! anygoodname_cp77_story_quest_fixes.archive', 'archive/pc/mod/! anygoodname_cp77_story_quest_fixes.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/anygoodname_cp77_story_quest_fixes/LICENSE', 'bin/x64/plugins/cyber_engine_tweaks/mods/anygoodname_cp77_story_quest_fixes/Ref.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/anygoodname_cp77_story_quest_fixes/init.lua'],
    'Minor Activities Quest Fixes 27162 1.15.1 2026-11-07T12-54Z Q6xF6lDa0.zip': ['archive/pc/mod/! minor_activities_quest_fixes.archive', 'archive/pc/mod/! minor_activities_quest_fixes.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/minor_activities_quest_fixes/LICENSE', 'bin/x64/plugins/cyber_engine_tweaks/mods/minor_activities_quest_fixes/Ref.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/minor_activities_quest_fixes/init.lua'],
    "Holdin' On - Kerrys' mansion scene bug fixes 1.0.0-25792-1-0-0-1763824954.zip": ['archive/pc/mod/! holding_on_kerry_mansion_scene_fixes.archive'],
    'Quest Vehicle Motion Fixes 24772 1.10.1 2026-06-27T11-30Z AgoGgivYq.zip': ['archive/pc/mod/! quest_vehicle_motion_fixes.archive', 'archive/pc/mod/! quest_vehicle_motion_fixes.xl'],
    'Delete -A Few Weeks Tops- Voiceline UNTESTED-16932-1-0-1728722317.zip': ['archive/pc/mod/Delete Few Weeks Tops.archive'],
    'Fix Advert Animations-17726-1-1-1745805020.zip': ['archive/pc/mod/!Fix_Advert_Animations.archive'],
    'AirTrafficDupeFix 31304 1.0.0 2026-07-08T02-36Z 5em9eoIRj.zip': ['archive/pc/mod/AirTrafficDupeFix.archive'],
}
ROUND12 = {   # round 12: cars, character-creator options, an outfit, gameplay fixes and a roulette; the chosen
    # files (their real game folders, from the downloads) and the files their rules pass over
    'KRNLNIK Audi R8 LBW SPOILERS STICKERS AND AERODISC-8827-1-0-1689974360.zip': ['R8 optional/spoiler lbw/KRNLNIK_R8_Optional_spoiler_lbw.archive', 'R8 optional/lbw stickers/KRNLNIK_R8_Optional_lbw_stickers.archive', 'R8 optional/front rotiform aerodisc/KRNLNIK_R8_Optional_rotiform_aerodisc.archive', 'R8 optional/ducktale/KRNLNIK_R8_Optional_ducktale.archive'],
    'KRNLNIK Audi R8 LBW-8827-1-3-1775612458.zip': ['archive/pc/mod/KRNLNIK_Audi_R8_LBW.archive', 'archive/pc/mod/audi_r8_lbw.xl', 'r6/tweaks/krnlnik/audi_r8_lbw.tweak', 'r6/tweaks/krnlnik/audi_r8_lbw_ICONS.tweak'],
    'KRNLNIK RTR Spec 5-8912-1-4-1775612450.zip': ['archive/pc/mod/KRNLNIK_RTR_Spec_5.archive', 'archive/pc/mod/rtr_spec5.xl', 'r6/tweaks/krnlnik/ford_rtr_spec5.tweak', 'r6/tweaks/krnlnik/ford_rtr_spec5_ICONS.tweak'],
    'Countach (without Neon)-11110-1-0-1700485296.zip': ['archive/pc/mod/ctrlsec_CountachUnbound.archive', 'archive/pc/mod/ctrlsec_CountachUnbound.xl', 'r6/tweaks/ctrlsec_CountachUnbound.yaml'],
    'Red neon-11110-1-0-1700485339.zip': ['archive/pc/mod/ctrlsec_CountachUnbound_Neon.archive'],
    'blue neon-11110-1-0-1700485366.zip': ['archive/pc/mod/blue_neon.archive'],
    'gren neon-11110-1-0-1700485385.zip': ['archive/pc/mod/gren_neon.archive'],
    'orange neon-11110-1-0-1700485401.zip': ['archive/pc/mod/orange_neon.archive'],
    'purple or pink neon-11110-1-0-1700485443.zip': ['archive/pc/mod/pink_neon.archive'],
    'yellow-11110-1-0-1700485461.zip': ['archive/pc/mod/yellow.archive'],
    'Countach (with Neon)-11110-1-0-1700489562.zip': ['archive/pc/mod/Countach_with_Neon.archive'],
    'Countach (with Neon) (No Spoiler)-11110-1-0-1700551977.zip': ['archive/pc/mod/Countach_with_Neon_No_Spoiler.archive'],
    'Countach (without Neon) (No Spoiler)-11110-1-0-1700552040.zip': ['archive/pc/mod/Countach_without_Neon_No_Spoiler.archive'],
    'alternative wheels and tires-11110-1-0-1700889034.zip': ['archive/pc/mod/alternative_wheels_and_tires.archive'],
    'Countach tweaks 2.1 update-11110-1-11-1701907009.zip': ['r6/tweaks/ctrlsec_CountachUnbound.yaml'],
    'Gambling Props-15229-1-0-1-1719189892.zip': ['archive/pc/mod/Gambling Props.archive', 'bin/x64/plugins/cyber_engine_tweaks/mods/AppearanceMenuMod/Collabs/Custom Props/boe6_poker_chip.lua'],
    'Gambling System - Roulette Props-15450-1-0-0-1748734679.zip': ['bin/x64/plugins/cyber_engine_tweaks/mods/AppearanceMenuMod/Collabs/Custom Props/boe6_gambling_system_roulette.lua'],
    'gambling-system-roulette-exampleaddon-15450-1-0-0-1765334481.zip': ['archive/pc/mod/gambling_system_roulette_exampleaddon.archive'],
    'Gambling System - Roulette 15450 1.1.4 2026-11-05T02-23Z tvQTvsRxv.zip': ['archive/pc/mod/Gambling System - Roulette.archive', 'archive/pc/mod/gambling_system_roulette.xl', 'archive/pc/mod/gambling_system_roulette_auto_generated.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/EntityManager.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/External/Cron.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/External/GameLocale.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/External/GameSession.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/External/GameUI.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/External/interactionUI.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/HolographicValueDisplay.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/JsonData.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/README.md', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/RelativeCoordinateCalulator.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/RouletteAnimations.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/RouletteCoordinates.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/RouletteMainMenu.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/SpotManager.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/TableManager.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/addons/null.txt', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/chipBetPiles.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/chipPlayerPile.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/chipUtils.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/init.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/Gambling System - Roulette/lang/en-us.lua'],
    'plain black livery with white decals-16570-1-1725880133.zip': ['archive/pc/mod/ctrlsec_0_Hycade_R34_Livery.archive'],
    'plain white livery with black decals-16570-1-1725880177.zip': ['archive/pc/mod/ctrlsec_0_Hycade_R34_Livery.archive'],
    'uv template for livery creators-16570-1-1725884236.zip': ['archive/pc/mod/uv_template_for_livery_creators.archive'],
    'infinity rims-16570-1-11-1728516252.zip': ['archive/pc/mod/ctrlsec_0_Hycade_R34_wheels.archive'],
    'hycade r34-16570-1-12-1734939448.zip': ['archive/pc/mod/ctrlsec_Hycade_R34.archive', 'archive/pc/mod/ctrlsec_Hycade_R34.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/NovaTraffic/community/Hycade_r34.json', 'r6/tweaks/ctrlsec/ctrlsec_Hycade_R34.yaml'],
    'LC 500 Paintjob Tutorial-16979-1-0-1728122765.zip': ['archive/pc/mod/LC_500_Paintjob_Tutorial.archive'],
    'LC 500 Paintjob resource file-16979-1-1728122801.zip': ['grldy/lexus_lc500_lbwk/color/material_instance/lc500_user.mi'],
    'LC 500 Modifications-16979-1-2-1728323916.zip': ['archive/pc/mod/LC_500_Modifications.archive'],
    'Lexus LC 500 All in One-16979-1-4-1733366472.zip': ['Lexus LC 500 All in One/README!.txt', 'Lexus LC 500 All in One/archive/pc/mod/grldy_Lexus_LC500_LBWK.archive.xl', 'Lexus LC 500 All in One/archive/pc/mod/grldy_lexus_lc500_lbwk.archive', 'Lexus LC 500 All in One/lbwk remap.png', 'Lexus LC 500 All in One/r6/tweaks/GRLDYLEE/grldy_Lexus_LC500_LBWK.yaml'],
    'Lexus LC 500 Dedka Car Dealership Support-16979-1-0-1761938730.zip': ['bin/x64/plugins/cyber_engine_tweaks/mods/Dedka Auto Shop/cars/ra5532.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/Dedka Auto Shop/cars', 'bin/x64/plugins/cyber_engine_tweaks/mods/Dedka Auto Shop', 'bin/x64/plugins/cyber_engine_tweaks/mods', 'bin/x64/plugins/cyber_engine_tweaks', 'bin/x64/plugins', 'bin/x64', 'bin'],
    'ColorPack-17998-1-1-1732861384.zip': ['archive/pc/mod/ColorPack.archive'],
    'Diablo_MainFile-17998-0-9-4-5-1737313361.zip': ['archive/pc/mod/diablo.archive', 'archive/pc/mod/diablo.archive.xl', 'r6/scripts/diablo/diablo_popup.reds', 'r6/tweaks/diablo/diablo.yaml'],
    'Tuning Parts-17998-0-9-4-1737450683.zip': ['archive/pc/mod/Tuning_Parts.archive'],
    'Beautiful Eyebrows - 01 - Default - CCXL-18783-2-0-1765149346.zip': ['archive/pc/mod/Arkhe_Beautiful_Eyebrows_01_DEFAULT_CCXL.archive', 'archive/pc/mod/Arkhe_Beautiful_Eyebrows_01_DEFAULT_CCXL.xl'],
    'Beautiful Eyebrows - 01 - Fuller - CCXL-18783-1-0-1765149390.zip': ['archive/pc/mod/Beautiful_Eyebrows_01_Fuller_CCXL.archive'],
    'Hair Profiles CCXL 1.02-19115-1-02-1737536097.zip': ['archive/pc/mod/id_hair_profiles_ccxl.archive', 'archive/pc/mod/id_hair_profiles_ccxl.xl', 'r6/tweaks/id_hair_profiles_ccxl/id_hair_profiles_ccxl_OptionsIcons.yaml'],
    'R35 nomad road tires and rims-20237-1-0-1741526632.zip': ['archive/pc/mod/R35_nomad_road_tires_and_rims.archive'],
    'r35 nomad road tires and turbofan infinite-20237-1-0-1741526661.zip': ['archive/pc/mod/r35_nomad_road_tires_and_turbofan_infinite.archive'],
    'UV for livery creators-20237-uv-1741533734.zip': ['archive/pc/mod/UV_for_livery_creators.archive'],
    'R35 nomad silver exhaust-20237-1-0-1741544043.zip': ['archive/pc/mod/R35_nomad_silver_exhaust.archive'],
    'R35 nomad disable neon trims-20237-1-03-1742304672.zip': ['archive/pc/mod/R35_nomad_disable_neon_trims.archive'],
    'r35 nomad enable neon-20237-1-05-1753032683.zip': ['archive/pc/mod/r35_nomad_enable_neon.archive'],
    'r35 nomad livery 2 20237 1.1 2026-10-31T09-20Z tvQTvs8LU.zip': ['archive/pc/mod/r35_nomad_livery_2.archive'],
    'r35 nomad clean crystalcoat 20237 1.1 2026-10-31T09-20Z NEnvE3WVV.zip': ['archive/pc/mod/r35_nomad_clean_crystalcoat.archive'],
    'r35 nomad livery 1 20237 1.1 2026-10-31T09-20Z X32s3EhPN.zip': ['archive/pc/mod/r35_nomad_livery_1.archive'],
    '1. R35 nomad main 20237 1.1 2026-10-31T09-26Z Z0ER0Bjz2.zip': ['archive/pc/mod/ctrlsec_R35unb_nomad.archive', 'archive/pc/mod/ctrlsec_R35unb_nomad.xl', 'r6/tweaks/ctrlsec/ctrlsec_UnboundR35_Nomad.yaml'],
    '2. R35 nomad hozuki sti engine sounds 20237 1.1 2026-10-31T09-31Z LACBAIvJC.zip': ['archive/pc/mod/2_R35_nomad_hozuki_sti_engine_sounds.archive'],
    '2. R35 nomad shion nomad engine sounds 20237 1.1 2026-10-31T09-32Z KRvfRxoym.zip': ['r6/tweaks/ctrlsec/ctrlsec_UnboundR35_Nomad.yaml'],
    'Vw Beetle Livery Template 20785 1.0 2026-09-29T18-16Z ozVyzbX9j.zip': ['archive/pc/mod/Vw_Beetle_Livery_Template.archive'],
    'VW Super Beetle 20785 2.0.2 2026-10-21T09-30Z 2w0lw11gD.zip': ['archive/pc/mod/sdh0_vwsuperbeetle.archive', 'archive/pc/mod/sdh0_vwsuperbeetle.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/SDH0_VWSuperBeetle/data/idlePaths.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/SDH0_VWSuperBeetle/data/pointCloud.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/SDH0_VWSuperBeetle/init.lua', 'r6/scripts/SDH0_VWSuperBeetle/sdh0_vwsuperbeetle_audio.reds', 'r6/scripts/SDH0_VWSuperBeetle/sdh0_vwsuperbeetle_meshconfig.reds', 'r6/tweaks/SDH0_VWSuperBeetle/sdh0_vwsuperbeetle.yaml'],
    'SDH0 Vehicle Resources 20956 2.0.1 2026-10-06T02-03Z FKtYKryyX.zip': ['archive/pc/mod/colorpack.archive', 'archive/pc/mod/sdh0_colorpack.xl', 'r6/tweaks/SDH0_ColorPack/sdh0_colorpack.yaml'],
    'PROP - Harley-Davidson Thundergod-21522-1-0-0-1747404800.zip': ['archive/pc/mod/PinkyDude_MitchsGarage_HarleyDavidsonThundergod_PROP.archive', 'bin/x64/plugins/cyber_engine_tweaks/mods/AppearanceMenuMod/Collabs/Custom Props/PinkyDude_MitchsGarage_HarleyDavidsonThundergod_PROP.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/entSpawner/data/favorite/Motorbike_1747313698.json'],
    'Thundergod Template for Pose Making-21522-1-0-0-1747404882.zip': ['archive/pc/mod/Thundergod_Template_for_Pose_Making.archive'],
    'Harley-Davidson Thundergod-21522-1-1-0-1760701549.zip': ['archive/pc/mod/PinkyDude_MitchsGarage_HarleyDavidsonThundergod.archive', 'archive/pc/mod/PinkyDude_MitchsGarage_HarleyDavidsonThundergod.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/Dedka Auto Shop/cars/ra1605.json', 'r6/tweaks/PinkyDude_MitchsGarage/pkd_hdthundergod.yaml'],
    'Bugatti Tourbillon - Main-22107-1-0-0-1749928023.zip': ['archive/pc/mod/MAXSA5 --- Bugatti_Tourbillon.archive', 'archive/pc/mod/MAXSA5 --- Bugatti_Tourbillon.xl', 'r6/scripts/bugatti_v16_tourbillon/bugatti_v16_tourbillon_mediaplayer.reds', 'r6/tweaks/bugatti_v16_tourbillon/bugatti_v16_tourbillon.tweak', 'r6/tweaks/bugatti_v16_tourbillon/bugatti_v16_tourbillon_ICONS.tweak'],
    'Bugatti Tourbillon - Extras-22107-1-0-5-1750141617.zip': ['archive/pc/mod/Bugatti_Tourbillon_Extras.archive'],
    'The Division Hunter Outfit-24902-1-1-1760199724.zip': ['archive/pc/mod/hunter_outfit.archive', 'archive/pc/mod/hunter_outfit.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/AppearanceMenuMod/Collabs/Custom Props/hunter_outfit/hunter_props.lua', 'r6/scripts/Hunter Outfit/shd_armory_store.reds', 'r6/scripts/Hunter Outfit/shd_patches_store.reds', 'r6/tweaks/hunter_outfit/hunter_outfit.yaml'],
    'Livery Template-24910-1-0-1760549637.zip': ['archive/pc/mod/Livery_Template.archive'],
    '458spiderWBK MainFile 24910 2.0.0 2026-10-06T00-52Z sHlUHDiiZ.zip': ['archive/pc/mod/sdh0_ferrari458spwbk.archive', 'archive/pc/mod/sdh0_ferrari458spwbk.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/SDH0_Ferrari458SpiderWBK/data/pointCloud.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/SDH0_Ferrari458SpiderWBK/init.lua', 'r6/scripts/SDH0_Ferrari458SpiderWBK/sdh0_ferrari458spwbk_audio.reds', 'r6/scripts/SDH0_Ferrari458SpiderWBK/sdh0_ferrari458spwbk_meshconfig.reds', 'r6/scripts/SDH0_Ferrari458SpiderWBK/sdh0_ferrari458spwbk_roof.reds', 'r6/tweaks/SDH0_Ferrari458SpiderWBK/sdh0_ferrari458spwbk.yaml'],
    "Ferrari458SpiderWBK SDH0's Vehicle Audio Ver 24910 1.0 2026-10-09T07-17Z D2ZS2nM76.zip": ['archive/pc/mod/Ferrari458SpiderWBK_SDH0_s_Vehicle_Audio_Ver.archive'],
    'Sedth_CCXL_eyelashes_FEM_V1-25068-2-1760658021.zip': ['archive/pc/mod/!!!!!!_SEDTH_ccxl eyelashes(FEM).archive', 'archive/pc/mod/!!!!!!_SEDTH_ccxl eyelashes(FEM).xl'],
    'Sedth_CCXL_eyelashes_FEM_V2-25068-2-1760658036.zip': ['archive/pc/mod/Sedth_CCXL_eyelashes_FEM_V2.archive'],
    'Sedth_CCXL_eyelashes_FEM_V3-25068-2-1760658051.zip': ['archive/pc/mod/Sedth_CCXL_eyelashes_FEM_V3.archive'],
    'Sedth_CCXL_eyelashes_FEM_V4-25068-2-1760658064.zip': ['archive/pc/mod/Sedth_CCXL_eyelashes_FEM_V4.archive'],
    'Sedth_CCXL_eyelashes_FEM_V1_EKT_Asian-25068-2-1760658112.zip': ['archive/pc/mod/Sedth_CCXL_eyelashes_FEM_V1_EKT_Asian.archive'],
    'Sedth_CCXL_eyelashes_FEM_V2_EKT_Asian-25068-2-1760658135.zip': ['archive/pc/mod/Sedth_CCXL_eyelashes_FEM_V2_EKT_Asian.archive'],
    'SEDTH_ccxl eyelashes(MALE)-25068-1-1760658169.zip': ['archive/pc/mod/!!!_SEDTH_ccxl eyelashes(MALE).archive', 'archive/pc/mod/!!!_SEDTH_ccxl eyelashes(MALE).xl'],
    'Preem Mirrors (Full)-25633-1-3-1b-1763678395.zip': ['archive/pc/mod/Preem_Mirrors_Full.archive'],
    'Preem Mirrors - Enable Player Reflection - INI-25633-1-0-0c-1763947413.zip': ['engine/config/platform/pc/!-enableplayeravatar.ini'],
    'Preem Mirrors (Lite)-25633-1-3-1-1763951538.zip': ['archive/pc/mod/###-PreemMirrors.archive'],
    'Beautiful Eyebrows - 02 - Default - CCXL-26168-1-0-1765398330.zip': ['archive/pc/mod/Arkhe_Beautiful_Eyebrows_02_DEFAULT_CCXL.archive', 'archive/pc/mod/Arkhe_Beautiful_Eyebrows_02_DEFAULT_CCXL.xl'],
    'Beautiful Eyebrows - 02 - Fuller - CCXL-26168-1-0-1765398379.zip': ['archive/pc/mod/Beautiful_Eyebrows_02_Fuller_CCXL.archive'],
    '404NotFound Traffic Lights Resolved-27956-1-8-4-1773620044.zip': ['engine/config/platform/pc/TrafficLightsResolved.ini', 'r6/scripts/TrafficLightsResolved/Init.reds'],
    'Disable Crystalcoat On Rims-29122-1-0-1778955915.zip': ['archive/pc/mod/Disable_Crystalcoat_On_Rims.archive'],
    'Swap Rims With Turbofan-29122-1-1778955992.zip': ['archive/pc/mod/Swap_Rims_With_Turbofan.archive'],
    'Blue turbofan color-29122-1-1778956180.zip': ['archive/pc/mod/Blue_turbofan_color.archive'],
    'Darkblue turbofan color-29122-1-1778956198.zip': ['archive/pc/mod/Dark_blue_turbofan_color.archive'],
    'Green turbofan color-29122-1-1778956208.zip': ['archive/pc/mod/Green_turbofan_color.archive'],
    'Limegreen turbofan color-29122-1-1778956218.zip': ['archive/pc/mod/Lime_green_turbofan_color.archive'],
    'Orange turbofan color-29122-1-1778956228.zip': ['archive/pc/mod/Orange_turbofan_color.archive'],
    'Pink turbofan color-29122-1-1778956238.zip': ['archive/pc/mod/Pink_turbofan_color.archive'],
    'Purple turbofan color-29122-1-1778956268.zip': ['archive/pc/mod/Purple_turbofan_color.archive'],
    'Red turbofan color-29122-1-1778956284.zip': ['archive/pc/mod/Red_turbofan_color.archive'],
    'White turbofan color-29122-1-1778956293.zip': ['archive/pc/mod/White_turbofan_color.archive'],
    'Yellow turbofan color-29122-1-1778956301.zip': ['archive/pc/mod/Yellow_turbofan_color.archive'],
    'uv maps for livery creators-29122-uv-1778960410.zip': ['archive/pc/mod/uv_maps_for_livery_creators.archive'],
    'Neon Enabler 29122 2.0 2026-10-03T13-44Z PYMIYqn6Y.zip': ['archive/pc/mod/Neon_Enabler.archive'],
    'More Grip 29122 2.1 2026-10-04T21-19Z NEnvE3qbM.zip': ['archive/pc/mod/More_Grip.archive'],
    'Quadra Turbo-Z - Garage Tuning Scripts 29122 2.11 2026-10-05T15-53Z ymA1m8sQ3.zip': ['bin/x64/plugins/cyber_engine_tweaks/mods/ctrlsec_quadra_turbo_z/data/pointCloud.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/ctrlsec_quadra_turbo_z/init.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/ctrlsec_quadra_turbo_z_vtech/data/pointCloud.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/ctrlsec_quadra_turbo_z_vtech/init.lua', 'r6/scripts/ctrlsec/Quadra Turbo Z/ctrlsec_quadra_turbo_z_meshconfig.reds', 'r6/scripts/ctrlsec/Quadra Turbo Z/ctrlsec_quadra_turbo_z_vtech_meshconfig.reds'],
    'Quadra Turbo-Z 29122 2.11 2026-10-05T15-55Z UQrhQSCyE.zip': ['archive/pc/mod/ctrlsec_0_quadra_turbo_z_liveries.archive', 'archive/pc/mod/ctrlsec_quadra_turbo_z.archive', 'archive/pc/mod/ctrlsec_quadra_turbo_z.xl', 'bin/x64/plugins/cyber_engine_tweaks/mods/Dedka Auto Shop/cars/ra5393.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/NovaTraffic/community/quadra_turbo_z.json', 'r6/tweaks/ctrlsec/ctrlsec_Quadra_Turbo_Z.yaml'],
    'Turbo Z update 2.5 hotfix 29122 2.11.1 2026-10-31T10-24Z cB3xB0Tbt.zip': ['archive/pc/mod/ctrlsec_0_quadra_turbo_z_liveries.archive', 'archive/pc/mod/ctrlsec_quadra_turbo_z.archive'],
    'Vehicle Core 31684 1.0.0 2026-09-13T21-12Z Q6xF6lxoS.zip': ['bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/init.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/lang/de_de.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/lang/en_us.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/lang/ko_kr.json', 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/modules/GameUI.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/modules/Helpers.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/modules/Localization.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/modules/Palettes.lua', 'bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCore/modules/Utils.lua', 'r6/scripts/VehicleCore/VehicleBase.reds', 'r6/scripts/VehicleCore/VehicleCoreBridge.reds', 'r6/scripts/VehicleCore/VehicleEntityWatcher.reds', 'r6/scripts/VehicleCore/VehicleMeshMapping.reds', 'r6/scripts/VehicleCore/VehicleSystem.reds'],
    'CORNMILF X RadekStepan WDG3 37099 1 2026-11-03T04-00Z mPgaPVXaX.zip': ['archive/pc/mod/CORNMILF_x_RadekStepan_WDG3.archive', 'archive/pc/mod/crs_wedge_3.xl', 'r6/scripts/cornmilf_cars/wdg3_headlight_block.reds', 'r6/tweaks/cornmilf/crs_wedge_3.tweak', 'r6/tweaks/cornmilf/crs_wedge_3_ICONS.tweak'],
    'WDG3 Alt Front RIms 37099 1 2026-11-03T04-06Z 5em9eol9i.zip': ['archive/pc/mod/###WDG3_Alt_Front_Rims.archive'],
    'Perks And Skills Fixes 1.0.0 37252 1.0.0 2026-11-04T16-24Z YfTif74jt.zip': ['r6/scripts/PerksAndSkillsFixes/PerksAndSkillsFixes.reds', 'r6/scripts/PerksAndSkillsFixes/Texts.en-us.reds', 'r6/scripts/PerksAndSkillsFixes/Texts.reds', 'r6/tweaks/PerksAndSkillsFixes.yaml'],
    'Black Lace Load Fix 1.0 37404 1 2026-11-05T19-15Z 9ka2kyC8C.zip': ['LICENSE', 'red4ext/plugins/BlackLaceLoadFix/BlackLaceLoadFix.dll', 'red4ext/plugins/BlackLaceLoadFix/BlackLaceLoadFix.ini', 'red4ext/plugins/BlackLaceLoadFix/BlackLaceLoadFix.pdb', 'red4ext/plugins/BlackLaceLoadFix/LICENSE', 'red4ext/plugins/BlackLaceLoadFix/RED4ext.SDK.LICENSE.txt', 'red4ext/plugins/BlackLaceLoadFix/RED4ext.SDK.THIRD_PARTY_LICENSES.txt'],
}

ROUND13 = {   # round 13: GEAR, two hairstyles, the Comfy Boots texture fix and four cars; the chosen files (their
    # real game folders, from the downloads) and the files their rules pass over
    'GEAR 37913 2.5-1 2026-11-09T23-34Z AgoGgiPhk.zip': ['archive/pc/mod/GEAR.archive', 'archive/pc/mod/GEAR.archive.xl', 'r6/scripts/GEAR/GEAR.reds', 'r6/tweaks/GEAR/gear.yaml', 'r6/tweaks/GEAR/gear_looks.yaml', 'r6/tweaks/GEAR/gear_slots.yaml'],
    'Atomiic Selkie Hair CCXL 37381 1 2026-11-08T05-31Z PYMIYqWbh.zip': ['archive/pc/mod/Atomiic_Selkie_Hair_CCXL.archive', 'archive/pc/mod/atomiic_selkie_hair_ccxl.xl'],
    "Firestarter Kai'sa Hair CCXL 37302 1 2026-11-04T21-54Z 3dwHd9Gd8.zip": ['archive/pc/mod/_0_Vesna_HoV_HAIR_FV_Kaisa_CCXL.archive', 'archive/pc/mod/_0_Vesna_HoV_HAIR_FV_Kaisa_CCXL.archive.xl', 'archive/pc/mod/_0_Vesna_HoV_HAIR_FV_Kaisa_CCXL_NO_PHYSICS.archive.xl'],
    'The patch file 37842 1 2026-11-09T05-52Z X32s3EBww.zip': ['r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_military_accessories_zenitex_goggles.yaml', 'r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_military_armored_ballistic_vest.yaml', 'r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_military_combat_armor.yaml', 'r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_military_combat_boots.yaml', 'r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_military_covert_shoes.yaml', 'r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_military_dual_pistol_holsters.yaml', 'r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_military_zenitex_backpack.yaml', 'r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_military_zenitex_underwear.yaml', 'r6/tweaks/scorpiontank/zz_zenitex_core5_addon_scorpion_zenitex_sleeveless_turtleneck.yaml', 'r6/tweaks/scorpiontank', 'r6/tweaks', 'r6'],
    'Patch for Comfy Boots 37842 0.1 2026-11-09T12-56Z Q6xF6lDcm.zip': ['archive/pc/mod/comfy-fix.archive'],
    'Lamborghini Huracan EVO 37520 1.0.0 2026-11-10T08-05Z k8Iw8moEh.zip': ['archive/pc/mod/MAXSA5_Lamborghini_Huracan_EVO.archive', 'r6/scripts/maxsa5/lamborghini_huracan_evo_weapons.reds', 'r6/tweaks/maxsa5/lamborghini_huracan_evo.tweak', 'r6/tweaks/maxsa5/lamborghini_huracan_evo_ICONS.tweak', 'archive/pc/mod/MAXSA5_Lamborghini_Huracan_EVO.xl'],
    'Lamborghini Huracan EVO - Disable Mirrors 37520 1.0.0 2026-11-10T08-07Z SlR4l6HTd.zip': ['archive/pc/mod/#MAXSA5_Lamborghini_Huracan_EVO_DISABLE_MIRRORS.archive'],
    'Lamborghini Huracan EVO - Custom Audio 37520 1.0.0 2026-11-10T08-08Z LACBAIm2B.zip': ['r6/scripts/maxsa5/lamborghini_huracan_evo_audio.reds', 'r6/tweaks/maxsa5/lamborghini_huracan_evo_AUDIO.tweak'],
    "Chevrolet Corvette C8 ZR1 '26 37929 1.5 2026-11-10T13-47Z HncQn2EKr.zip": ['archive/pc/mod/ninegage_corvette_c8_zr1.archive', 'archive/pc/mod/ninegage_corvette_c8_zr1.archive.xl', 'r6/scripts/Ninegage/corvette_c8_zr1.reds', 'r6/tweaks/ninegage_corvette_c8_zr1.yaml'],
    'Ford Hennessey VelociRaptor 6x6 Remastered v1.2 36409 3 2026-11-01T19-41Z YfTif7daR.zip': ['archive/pc/mod/bonk_ford_hennessey.xl', 'archive/pc/mod/Ford Hennessey V3.archive', 'r6/tweaks/Ford Hennessey V3/bonk_ford_hennessey.yaml'],
    'CORNMILF Ford Fronco Bronco 29942 1 2026-11-03T02-26Z gMz5Mu25T.zip': ['archive/pc/mod/fronco_bronco.xl', 'r6/tweaks/cornmilf/ford_bronco_raptor_fronco_ICONS.tweak', 'archive/pc/mod/CORNMILF_Ford_Fronco_Bronco.archive', 'r6/tweaks/cornmilf/ford_bronco_raptor_fronco.tweak'],
}
ROUND9_FILES = {   # real contents, where the tests read a file: a key binding to move, settings to keep
    ('Always First Equip 2557 2.2.0 2026-10-24T19-15Z mPgaPVVHG.zip', 'r6/input/AlwaysFirstEquip.xml'): b'<?xml version="1.0"?>\r\n<bindings>\r\n    <!-- inputContexts -->\r\n    <context name="AlwaysFirstEquip" >\r\n        <action name="AlwaysFirstEquip" map="AlwaysFirstEquip_Button" />\r\n        <action name="SafeWeapon" map="SafeWeapon_Button" />\r\n    </context>\r\n\r\n    <context name="Items" append="true">\r\n        <include name="AlwaysFirstEquip" />\r\n    </context>\r\n\t\r\n\t<hold action="AlwaysFirstEquip" timeout="0.4" />\r\n\r\n    <!-- inputUserMapping -->\r\n\t<mapping name="AlwaysFirstEquip_Button" type="Button" >\r\n        <button id="IK_F2" overridableUI="afeMainHotkey" />\r\n    </mapping>\r\n\t<mapping name="SafeWeapon_Button" type="Button" >\r\n        <button id="IK_F3" overridableUI="afeAdditionalHotkey" />\r\n    </mapping>\r\n</bindings>\r\n',
    ('Sit Anywhere 1.4-7299-1-4-1762025971.zip', 'bin/x64/plugins/cyber_engine_tweaks/mods/sitAnywhere/config/config.json'):
        b'{"sitAnimation":1,"hideExitPopup":false,"hideUI":true}',
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
    github('Input_Loader', 'flight,mods', 'lib', 'game', 'red4ext/plugins/input_loader/input_loader.dll', '0.2.6', 'input_loader_v0.2.6.zip', {
        'red4ext/plugins/input_loader/input_loader.dll': f'{pe}/il/input_loader.dll',
        'r6/cache/inputContexts.xml': b'<bindings loader="0.2.6"/>\r\n',
        'r6/cache/inputUserMappings.xml': b'<mappings loader="0.2.6"/>\r\n',
        'engine/config/platform/pc/input_loader.ini': b'[Player/Input]\r\n'})
    make_pe(f'{pe}/ltbf/let_there_be_flight.dll', '0.3.20', '2.50', linker=(14, 44), imports=CRT, strings={'Comments': 'Built for 2.50'})
    github('Let_There_Be_Flight', 'flight,mods', 'mod', 'game', 'red4ext/plugins/let_there_be_flight/let_there_be_flight.dll', '0.3.20',
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
                f'{d}/Data/user_setting_v3.json': b'{"language": "default", "common_keybind_table": [{"key": "IK_5", "name": '
                                                  b'"toggle_appearance", "pad": "", "is_hold": false}]}\n',
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
    for name, paths in ROUND4.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round4/{zname}', {p: placeholder(p, name) for p in paths})
    for name, paths in ROUND5.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round5/{zname}', {p: placeholder(p, name) for p in paths})
    for name, paths in ROUND7.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round7/{zname}', {p: placeholder(p, name) for p in paths})
    for name, paths in ROUND9.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round9/{zname}', {p: ROUND9_FILES.get((name, p)) or placeholder(p, name) for p in paths})
    for name, paths in ROUND10.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round10/{zname}', {p: placeholder(p, name) for p in paths})
    for name, paths in ROUND11.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round11/{zname}', {p: placeholder(p, name) for p in paths})
    for name, paths in ROUND12.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round12/{zname}', {p: placeholder(p, name) for p in paths})
    for name, paths in ROUND13.items():
        zname = re.sub(r'\.(rar|7z)$', '.zip', name)
        zipdir(f'{fix}/round13/{zname}', {p: placeholder(p, name) for p in paths})
    eqex = 'Equipment-EX 6945 1.2.11 2026-11-06T10-00Z Lt7Qw2zXa.zip'   # a later release, only on Nexus Mods
    zipdir(f'{fix}/nexus-later/{eqex}', {p: placeholder(p, eqex) for p in ROUND3['Equipment-EX 6945 1.2.10 2026-10-25T21-07Z k8Iw8mmPd.zip']})
    nexus_api(fix, sorted({r.split()[7].split(':')[1] for r in table if r.split()[7].startswith('nexus:')}, key=int))


# Nexus Mods' API, as files: what https://api.nexusmods.com/v1/... answers, under nexusapi/v1/...,
# for the fixtures' Nexus downloads. Its download links point at the archives themselves (file://).
NEXUS_NAMES = (r'^.+ %s (?P<ver>\S+) (?P<iso>\d{4}-\d\d-\d\dT\d\d-\d\dZ) [A-Za-z0-9]+\.(?:zip|7z|rar)$',
               r'^.+-%s-(?P<ver>[vV]?[0-9][0-9a-zA-Z-]*?)-(?P<ts>[0-9]{9,11})\.(?:zip|7z|rar)$')
NEXUS_CATEGORY = {   # what is not a main file
    'No Intro Videos-533-0-6-1730000000.zip': 'ARCHIVED',   # newer than 0.5, and no game folders: never taken
    'Virtual Atelier - Basic-2987-1-2-4-1706771312.zip': 'OLD_VERSION',
    'Vehicle Customizer SVE 3dot1 9034 3.1 2026-09-21T11-33Z tvQTvsQ74.zip': 'UPDATE',
    'Red neon-11110-1-0-1700485339.zip': 'MISCELLANEOUS',
    'blue neon-11110-1-0-1700485366.zip': 'MISCELLANEOUS',
    'gren neon-11110-1-0-1700485385.zip': 'MISCELLANEOUS',
    'orange neon-11110-1-0-1700485401.zip': 'MISCELLANEOUS',
    'purple or pink neon-11110-1-0-1700485443.zip': 'MISCELLANEOUS',
    'yellow-11110-1-0-1700485461.zip': 'MISCELLANEOUS',
    'Countach (with Neon) (No Spoiler)-11110-1-0-1700551977.zip': 'OPTIONAL',
    'Countach (without Neon) (No Spoiler)-11110-1-0-1700552040.zip': 'OPTIONAL',
    'alternative wheels and tires-11110-1-0-1700889034.zip': 'OPTIONAL',
    'Countach tweaks 2.1 update-11110-1-11-1701907009.zip': 'UPDATE',
    'Gambling System - Roulette Props-15450-1-0-0-1748734679.zip': 'OPTIONAL',
    'gambling-system-roulette-exampleaddon-15450-1-0-0-1765334481.zip': 'OPTIONAL',
    'plain black livery with white decals-16570-1-1725880133.zip': 'OPTIONAL',
    'plain white livery with black decals-16570-1-1725880177.zip': 'OPTIONAL',
    'uv template for livery creators-16570-1-1725884236.zip': 'MISCELLANEOUS',
    'infinity rims-16570-1-11-1728516252.zip': 'OPTIONAL',
    'LC 500 Paintjob Tutorial-16979-1-0-1728122765.zip': 'MISCELLANEOUS',
    'LC 500 Paintjob resource file-16979-1-1728122801.zip': 'MISCELLANEOUS',
    'LC 500 Modifications-16979-1-2-1728323916.zip': 'OPTIONAL',
    'Lexus LC 500 Dedka Car Dealership Support-16979-1-0-1761938730.zip': 'OPTIONAL',
    'ColorPack-17998-1-1-1732861384.zip': 'OPTIONAL',
    'Tuning Parts-17998-0-9-4-1737450683.zip': 'OPTIONAL',
    'R35 nomad road tires and rims-20237-1-0-1741526632.zip': 'MISCELLANEOUS',
    'r35 nomad road tires and turbofan infinite-20237-1-0-1741526661.zip': 'MISCELLANEOUS',
    'UV for livery creators-20237-uv-1741533734.zip': 'MISCELLANEOUS',
    'R35 nomad silver exhaust-20237-1-0-1741544043.zip': 'MISCELLANEOUS',
    'R35 nomad disable neon trims-20237-1-03-1742304672.zip': 'MISCELLANEOUS',
    'r35 nomad enable neon-20237-1-05-1753032683.zip': 'MISCELLANEOUS',
    'r35 nomad livery 2 20237 1.1 2026-10-31T09-20Z tvQTvs8LU.zip': 'MISCELLANEOUS',
    'r35 nomad clean crystalcoat 20237 1.1 2026-10-31T09-20Z NEnvE3WVV.zip': 'MISCELLANEOUS',
    'r35 nomad livery 1 20237 1.1 2026-10-31T09-20Z X32s3EhPN.zip': 'MISCELLANEOUS',
    '2. R35 nomad hozuki sti engine sounds 20237 1.1 2026-10-31T09-31Z LACBAIvJC.zip': 'OPTIONAL',
    '2. R35 nomad shion nomad engine sounds 20237 1.1 2026-10-31T09-32Z KRvfRxoym.zip': 'OPTIONAL',
    'Vw Beetle Livery Template 20785 1.0 2026-09-29T18-16Z ozVyzbX9j.zip': 'MISCELLANEOUS',
    'PROP - Harley-Davidson Thundergod-21522-1-0-0-1747404800.zip': 'OPTIONAL',
    'Thundergod Template for Pose Making-21522-1-0-0-1747404882.zip': 'MISCELLANEOUS',
    'Bugatti Tourbillon - Extras-22107-1-0-5-1750141617.zip': 'OPTIONAL',
    'Livery Template-24910-1-0-1760549637.zip': 'MISCELLANEOUS',
    "Ferrari458SpiderWBK SDH0's Vehicle Audio Ver 24910 1.0 2026-10-09T07-17Z D2ZS2nM76.zip": 'OPTIONAL',
    'Sedth_CCXL_eyelashes_FEM_V1_EKT_Asian-25068-2-1760658112.zip': 'OPTIONAL',
    'Sedth_CCXL_eyelashes_FEM_V2_EKT_Asian-25068-2-1760658135.zip': 'OPTIONAL',
    'SEDTH_ccxl eyelashes(MALE)-25068-1-1760658169.zip': 'UPDATE',
    'Preem Mirrors - Enable Player Reflection - INI-25633-1-0-0c-1763947413.zip': 'OPTIONAL',
    'Disable Crystalcoat On Rims-29122-1-0-1778955915.zip': 'OPTIONAL',
    'Swap Rims With Turbofan-29122-1-1778955992.zip': 'OPTIONAL',
    'Blue turbofan color-29122-1-1778956180.zip': 'MISCELLANEOUS',
    'Darkblue turbofan color-29122-1-1778956198.zip': 'MISCELLANEOUS',
    'Green turbofan color-29122-1-1778956208.zip': 'MISCELLANEOUS',
    'Limegreen turbofan color-29122-1-1778956218.zip': 'MISCELLANEOUS',
    'Orange turbofan color-29122-1-1778956228.zip': 'MISCELLANEOUS',
    'Pink turbofan color-29122-1-1778956238.zip': 'MISCELLANEOUS',
    'Purple turbofan color-29122-1-1778956268.zip': 'MISCELLANEOUS',
    'Red turbofan color-29122-1-1778956284.zip': 'MISCELLANEOUS',
    'White turbofan color-29122-1-1778956293.zip': 'MISCELLANEOUS',
    'Yellow turbofan color-29122-1-1778956301.zip': 'MISCELLANEOUS',
    'uv maps for livery creators-29122-uv-1778960410.zip': 'MISCELLANEOUS',
    'Neon Enabler 29122 2.0 2026-10-03T13-44Z PYMIYqn6Y.zip': 'OPTIONAL',
    'More Grip 29122 2.1 2026-10-04T21-19Z NEnvE3qbM.zip': 'OPTIONAL',
    'Turbo Z update 2.5 hotfix 29122 2.11.1 2026-10-31T10-24Z cB3xB0Tbt.zip': 'UPDATE',
    'WDG3 Alt Front RIms 37099 1 2026-11-03T04-06Z 5em9eol9i.zip': 'OPTIONAL',
    'Lamborghini Huracan EVO - Disable Mirrors 37520 1.0.0 2026-11-10T08-07Z SlR4l6HTd.zip': 'OPTIONAL',
    'Lamborghini Huracan EVO - Custom Audio 37520 1.0.0 2026-11-10T08-08Z LACBAIm2B.zip': 'OPTIONAL',
}
NEXUS_LATER = ('Drive an Aerial Vehicle 13842 3.5.1 2026-11-02T09-30Z Zx81kQp0a.zip',   # listed in nexusapi/later only
               'Equipment-EX 6945 1.2.11 2026-11-06T10-00Z Lt7Qw2zXa.zip')
NEXUS_NO_MD5 = ('hycade r34-16570-1-12-1734939448.zip',)   # Nexus Mods' MD5 index lacks it (November 2026)
NEXUS_NO_SIZE = ('CyberDrift 2.0 Light for game ver. 2.31 8306 2.31 2026-08-03T18-29Z 4rpqrKU17.zip',)   # as Nexus lists it


def nexus_api(fix, ids):
    api, game = f'{fix}/nexusapi/v1', f'{fix}/nexusapi/v1/games/cyberpunk2077/mods'
    account = {'user_id': 1, 'key': 'not-the-key', 'name': 'tester', 'is_premium?': True, 'is_supporter?': True,
               'email': 'tester@example.invalid', 'profile_url': '', 'is_supporter': True, 'is_premium': True}
    write(f'{api}/users/validate-premium.json', json.dumps(account))
    write(f'{api}/users/validate.json', json.dumps(account))
    write(f'{api}/users/validate-free.json', json.dumps(dict(account, **{'is_premium?': False, 'is_premium': False,
                                                                         'is_supporter?': False, 'is_supporter': False})))
    for period in ('?period=1d', '?period=1w', '?period=1m', ''):   # nothing changed lately (Python 3.14 opens a
        write(f'{game}/updated.json{period}', '[]')                  # file:// URL without its query)
    archives = []
    for d in ('nexus', 'style', 'round3', 'round4', 'round5', 'round7', 'round9', 'round10', 'round11', 'round12', 'round13', 'nexus-bad', 'nexus-later'):
        archives += [(n, f'{fix}/{d}/{n}') for n in sorted(os.listdir(f'{fix}/{d}'))]
    md5s, fid, lists = {}, 100000, {}
    for mod in ids:
        for n, path in archives:
            m = next((m for m in (re.match(pat % mod, n) for pat in NEXUS_NAMES) if m), None)
            if not m:
                continue
            fid += 1
            ts = int(m.group('ts')) if 'ts' in m.groupdict() and m.group('ts') else \
                calendar.timegm(time.strptime(m.group('iso'), '%Y-%m-%dT%H-%MZ'))
            data = open(path, 'rb').read()
            f = {'file_id': fid, 'name': n.rsplit('.', 1)[0], 'version': m.group('ver'), 'category_name': NEXUS_CATEGORY.get(n, 'MAIN'),
                 'size_in_bytes': None if n in NEXUS_NO_SIZE else len(data), 'file_name': n, 'uploaded_timestamp': ts, 'md5': None}
            lists.setdefault(mod, []).append(f)
            link = [{'name': 'Elsewhere', 'short_name': 'Elsewhere', 'URI': 'https://downloads.example.invalid/' + n},
                    {'name': 'Nexus Global Content Delivery Network', 'short_name': 'Nexus CDN', 'URI': 'file://' + path}]
            write(f'{game}/{mod}/files/{fid}/download_link.json', json.dumps(link))
            if n in NEXUS_NO_MD5:   # as Nexus Mods lists it: its MD5 index lacks the file, its virus scan names its SHA-256
                sha = hashlib.sha256(data).hexdigest()
                f['external_virus_scan_url'] = 'https://www.virustotal.com/gui/file/%s/detection/f-%s-1734944204' % (sha, sha)
                write(f'{fix}/nexusapi/no-md5-fid', str(fid))
                continue
            md5s.setdefault(hashlib.md5(data).hexdigest(), []).append(
                {'mod': {'mod_id': int(mod), 'name': 'mod %s' % mod}, 'file_details': dict(f, md5=hashlib.md5(data).hexdigest())})
    for mod, files in lists.items():
        now = [f for f in files if f['file_name'] not in NEXUS_LATER]
        write(f'{game}/{mod}/files.json', json.dumps({'files': now, 'file_updates': []}))
        if len(now) != len(files):   # its later list: the new release, the old one an old version
            later = [dict(f, category_name='OLD_VERSION') if f in now else f for f in files]
            write(f'{fix}/nexusapi/later/{mod}.files.json', json.dumps({'files': later, 'file_updates': []}))
    for md5, hits in md5s.items():
        write(f'{game}/md5_search/{md5}.json', json.dumps(hits))
    # Equipment-EX as a server could hand it over: changed in one byte, or cut short; and a link elsewhere only
    eq = 'Equipment-EX 6945 1.2.10 2026-10-25T21-07Z k8Iw8mmPd.zip'
    efid = next(f['file_id'] for f in lists['6945'] if f['file_name'] == eq)
    data = bytearray(open(f'{fix}/round3/{eq}', 'rb').read())
    data[len(data) // 2] ^= 0xff
    os.makedirs(f'{fix}/nexuscdn-bad', exist_ok=True)
    open(f'{fix}/nexuscdn-bad/{eq}', 'wb').write(bytes(data))
    os.makedirs(f'{fix}/nexuscdn-short', exist_ok=True)
    open(f'{fix}/nexuscdn-short/{eq}', 'wb').write(bytes(data[:len(data) // 2]))
    for v, uri in (('bad', f'file://{fix}/nexuscdn-bad/{eq}'), ('short', f'file://{fix}/nexuscdn-short/{eq}'),
                   ('elsewhere', 'https://downloads.example.invalid/' + eq)):
        write(f'{game}/6945/files/{efid}/download_link-{v}.json', json.dumps([{'name': v, 'short_name': v, 'URI': uri}]))
    shutil.copy(f'{game}/6945/files/{efid}/download_link.json', f'{game}/6945/files/{efid}/download_link-good.json')
    write(f'{fix}/nexusapi/eqex-fid', str(efid))

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
