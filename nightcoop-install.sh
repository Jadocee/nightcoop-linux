#!/usr/bin/env bash
# nightcoop-install.sh - NightCoop co-op mod for Cyberpunk 2077 on Arch Linux and SteamOS
#
# Installs NightCoop (https://nightcoop.net) into the Steam version of Cyberpunk 2077
# running under Proton. Written for:
#   - SteamOS 3 (Steam Deck and other SteamOS devices), run from Desktop Mode
#   - CachyOS, including its proton-cachyos builds
#   - Arch Linux and Arch-based systems (EndeavourOS, Manjaro, Garuda, ...)
# Other distributions with the native or Flatpak Steam client take the same path.
#
# Under Proton three things stop NightCoop, a RED4ext plugin, from loading:
#   1. Wine prefers its built-in winmm.dll to RED4ext's loader. The script adds a
#      per-game DLL override to the Proton prefix (this works while Steam is open)
#      and, when Steam is closed, merges it into the game's launch options as well.
#   2. Steam's first launch installs the 2019 Microsoft C++ runtime into the prefix.
#      RED4ext is built with a newer MSVC toolset and fails in it with
#      "RED4ext (error 998) No access to memory location". The script installs the
#      current Visual C++ runtime into the prefix.
#   3. Each RED4ext release supports one game patch; 2.5 needs 1.31. The script installs
#      the newest RED4ext that the installed game supports. Patches before 2.5 are refused.
# It also picks the Proton build for the game (proton-cachyos on CachyOS, otherwise
# Proton Experimental), unless one is already chosen in Steam.
#
# Usage:
#   nightcoop-install.sh [install] [options]   install NightCoop, or update it in place (default)
#   nightcoop-install.sh update [options]      the same as install
#   nightcoop-install.sh check                 report the current state and whether an update exists
#   nightcoop-install.sh restore [BACKUP_DIR]  undo the latest install (or the given one)
#   nightcoop-install.sh uninstall             undo every install, newest first
#
# Run again, it compares the game folder with the latest build for the game's patch and
# replaces only the files that differ. When everything is current, it changes nothing.
#
# Options:
#   --proton TOOL         Proton build for the game: auto (default), keep, experimental,
#                         cachyos, ge, or a tool name such as GE-Proton10-25
#   --no-launcher-skip    keep CDPR's launcher: do not add --launcher-skip to the launch options
#   --no-game-performance do not start the game with CachyOS's game-performance (added to the
#                         launch options when it can run); remembered, --game-performance undoes it
#   --mangohud            show MangoHud's overlay in the game (MANGOHUD=1 in the launch options;
#                         not on SteamOS, which has its own); --no-mangohud takes it out again
#   --close-steam         close Steam to write its settings, then reopen it
#   --nightcoop-zip FILE  use a downloaded NightCoop archive instead of the latest
#   --red4ext-zip FILE    use a downloaded RED4ext release archive
#   --vcredist FILE       use a downloaded VC_redist.x64.exe
#   --steam-root DIR      use this Steam installation instead of detecting one
#   --with-flight         also install Let There Be Flight (flying cars), which NightCoop
#                         supports in co-op, with what it needs; kept up to date afterwards
#   --without-flight      remove Let There Be Flight again (the mods it needed stay)
#   --with-mods           also install Virtual Atelier with clothing and item stores and their
#                         outfits (Zenitex, The RVC00N Dumpster, Nola Dreamer, Street Ninja),
#                         hairstyles (Preem Hair and packs for the character creator),
#                         Virtual Car Dealer with car and bike packs, Drive an Aerial Vehicle,
#                         Vehicle Customizer, Cyber Drift, Impact FX, Immersive Audio Distance,
#                         Quick Stash and No Intro Videos (download them from Nexus Mods; the
#                         installer lists them), with the frameworks they need (Cyber Engine
#                         Tweaks, Codeware, TweakXL, ArchiveXL, redscript, Mod Settings,
#                         Audioware, VendorsXL and more); kept up to date
#   --without-mods        remove those mods again (the frameworks stay)
#   --with-equipment-ex   also install Equipment-EX (from Nexus Mods), to wear layered outfits,
#                         and with --with-mods jewellery made for its slots; every partner in a
#                         session needs it too
#   --without-equipment-ex remove Equipment-EX again
#   --mods-from DIR       where the Nexus downloads are (default: your Downloads folder)
#   --force               reinstall every mod file, even those that already match
#   --backup-saves        copy the save games first (the default on a first install)
#   --no-save-backup      do not copy them (the default when updating an earlier install)
#   --dry-run             detect, download and verify everything; change nothing
#   -y, --yes             do not ask for confirmation
#   -h, --help            show this help
#
# Needs bash, python3, curl, coreutils, findutils and procps-ng. SteamOS and CachyOS
# ship all of them; on a minimal Arch install: sudo pacman -S --needed python curl

# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_VERSION="3.4.0"
APPID=1091500
GAME_EXE_REL="bin/x64/Cyberpunk2077.exe"
RED4EXT_VER="1.31.0"
RED4EXT_URL="https://github.com/wopss/RED4ext/releases/download/v${RED4EXT_VER}/red4ext-${RED4EXT_VER}.zip"
RED4EXT_SHA="b9ae4351f547f90af58dfbf7445d45c55cd5ba24fbee27fb16fb5d91e9df621e"
NIGHTCOOP_SITE="https://nightcoop.net"
# The v14 link serves the newest runtime (VS 2017-2026); the VS 2022 link is a fallback.
VCREDIST_URLS=("https://aka.ms/vc14/vc_redist.x64.exe" "https://aka.ms/vs/17/release/vc_redist.x64.exe")
# MSVC 14.40 changed std::mutex: anything built with it or later fails with error 998
# on an older msvcp140.dll. Newer builds should get a runtime at least as new as
# their toolset, which is read from the DLLs themselves.
RUNTIME_FLOOR="14.40"
# Each RED4ext release and the game build (Cyberpunk2077.exe file version) it requires;
# from RED4ext's own start-up check (RED4EXT_V1_RUNTIME_VERSION_* in RED4ext.SDK).
RED4EXT_COMPAT="1.31.0:3.0.88.46235"
REG_KEY='Software\Wine\AppDefaults\Cyberpunk2077.exe\DllOverrides'
RED4EXT_CORE=("red4ext/RED4ext.dll" "bin/x64/winmm.dll" "red4ext/LICENSE.txt" "red4ext/THIRD_PARTY_LICENSES.txt")
# The oldest game patch this installer supports: 2.5 (Cyberpunk2077.exe file version).
MIN_GAME_FILEVER="3.0.88.46235" MIN_GAME_PATCH="2.5"
# Add-on sets, matched to the game patch:
#   flight (--with-flight)  Let There Be Flight, which NightCoop supports in co-op: its
#                           archive ships the port (r6/scripts/NightCoopFlight), which
#                           compiles to nothing without it.
#   mods (--with-mods)      Virtual Atelier with stores of the game's own items and the stores of
#                           Zenitex, The RVC00N Dumpster 3, Nola Dreamer and Street Ninja with
#                           their outfits, hairstyles, Virtual Car Dealer with car and bike packs,
#                           Drive an Aerial Vehicle, Vehicle Customizer, Cyber Drift (Light), Impact
#                           FX, Immersive Audio Distance, Quick Stash and No Intro Videos, and the
#                           frameworks they need.
#   eqex (--with-equipment-ex)  Equipment-EX, which wears clothes in layers. NightCoop sends looks by
#                           its slots: a partner without it sees other slots.
#   mods+eqex               Only with both: raem's jewellery, made for Equipment-EX's slots, and
#                           the store that sells it.
# A component in both sets is installed once. When its sets are dropped (--without-...), a
# "mod" is removed and a "lib" stays, since other mods use it too.
# Source: a GitHub release (archive and pinned SHA-256), or nexus:<mod id>[:<prefer>[:<avoid>,...]]
# for a mod published only on Nexus Mods, which blocks scripted downloads: you download it,
# and the installer takes it from your Downloads folder (--mods-from DIR). For those, version is
# the oldest release known to work with the patch. Of several files of such a mod, one with
# <prefer> in its name wins ("+word": only such files, for a mod whose files go together, each
# its own component); one with an <avoid> word in its name is never installed (see
# nexus_avoided below; "~word": silently, as another component takes it). "_" in a word stands
# for a space.
# The pairings come from each project's README and release notes at the tag, and from the
# "Built for" game version in the plugins' DLLs.
# rule: a copy installed by hand stays when it is newer and "game": its DLL names the same
# patch (ProductVersion); "minor": the same major.minor release line; "-": never. The version
# file also identifies, by SHA-256, the release this script installed.
#   component                   patch sets        kind rule  version file  version  source  SHA-256
# >>> add-on sets
ADDON_SETS="
redscript                     2.5 flight,mods,eqex lib  -     engine/tools/scc_lib.dll                                    0.5.32 https://github.com/jac3km4/redscript/releases/download/v0.5.32/redscript-v0.5.32-windows.zip 882c57a80b07e453bc8a34cd8430f460aceed789581de8743638e19dcfb7936f
ArchiveXL                     2.5 flight,mods,eqex lib  minor red4ext/plugins/ArchiveXL/ArchiveXL.dll                     1.28.6 https://github.com/psiberx/cp2077-archive-xl/releases/download/v1.28.6/ArchiveXL-1.28.6.zip 25d0493a1b3e8ec4c26b7144a4d8f1a1def4d6dc840fff94b4c91c908583da09
TweakXL                       2.5 flight,mods,eqex lib  minor red4ext/plugins/TweakXL/TweakXL.dll                         1.12.0 https://github.com/psiberx/cp2077-tweak-xl/releases/download/v1.12.0/TweakXL-1.12.0.zip a7c39b769e6c51d9f27412a101fb87e6a1fb8452f0e37ee0d1d1f3f44e656fa8
Input_Loader                  2.5 flight      lib  game  red4ext/plugins/input_loader/input_loader.dll               0.2.6  https://github.com/jackhumbert/cyberpunk2077-input-loader/releases/download/v0.2.6/input_loader_v0.2.6.zip 6b420ba1e27b2e13c275a576a37a17d48771a0d35e52731f08e3584444a3e2b9
Let_There_Be_Flight           2.5 flight      mod  game  red4ext/plugins/let_there_be_flight/let_there_be_flight.dll 0.3.20 https://github.com/jackhumbert/let_there_be_flight/releases/download/v0.3.20/let_there_be_flight_v0.3.20.zip b265d3c6a711f0647d34835374652f5a84b7f3110df944e6d9059aaa7cbfa243
Codeware                      2.5 mods,eqex   lib  minor red4ext/plugins/Codeware/Codeware.dll                       1.21.2 https://github.com/psiberx/cp2077-codeware/releases/download/v1.21.2/Codeware-1.21.2.zip 269b65b8b97d26ea85d4516f5eb34c01a19dc85e299be57fb4f764e16c164dd2
Cyber_Engine_Tweaks           2.5 mods        lib  minor bin/x64/plugins/cyber_engine_tweaks.asi                     1.38.1 https://github.com/maximegmd/CyberEngineTweaks/releases/download/v1.38.1/cet_1_38_1.zip 2e52be4ed431fad787e64ecbf75db346b4224577d2b89894912bc3f159020e73
Mod_Settings                  2.5 mods        lib  game  red4ext/plugins/mod_settings/mod_settings.dll               0.2.28 https://github.com/jackhumbert/mod_settings/releases/download/v0.2.28/mod_settings_v0.2.28.zip b9488daa7da85c0430853df4570dbf94dd768d11c4dabee97d732072746d40e7
Audioware                     2.5 mods        lib  -     red4ext/plugins/audioware/audioware.dll                     1.11.1 https://github.com/cyb3rpsych0s1s/audioware/releases/download/v1.11.1/Audioware-windows-v1.11.1.zip 3831c9f931323a7462d84b8c391dded43288acf98af356a2d4ad4695c0603789
Native_Settings_UI            2.5 mods        lib  -     -                                                           1.97   nexus:3518
Virtual_Atelier               2.5 mods        mod  -     -                                                           1.6.4  nexus:2987
A.G.I.S.                      2.5 mods        mod  -     -                                                           1.2.1  nexus:10909:publicnet:legendary,blackwall
Night_City_Marketplace        2.5 mods        mod  -     -                                                           2.3.0  nexus:4433
Virtual_Car_Dealer            2.5 mods        mod  -     -                                                           2.3.0  nexus:4454
Quick_Stash                   2.5 mods        mod  -     -                                                           1.1    nexus:30016
No_Intro_Videos               2.5 mods        mod  -     -                                                           0.5    nexus:533:-:redscript
Cyber_Drift                   2.5 mods        mod  -     -                                                           2.31   nexus:8306:light
Drive_an_Aerial_Vehicle       2.5 mods        mod  -     -                                                           3.5.0  nexus:13842
All_Vanilla_Clothes           2.5 mods        mod  -     -                                                           1.0    nexus:5544
Iconic_Shops                  2.5 mods        mod  -     -                                                           3.6.1  nexus:7215
Zenitex_Virtual_Atelier       2.5 mods        mod  -     -                                                           4.13   nexus:10090
Zenitex_Ballistic_Mask        2.5 mods        mod  -     -                                                           4.1    nexus:12422:-:alt._colo,_-_gs
Zenitex_Tactical_Harness      2.5 mods        mod  -     -                                                           4.0    nexus:9774:-:alt._colo,_-_gs
Zenitex_Combat_Jacket         2.5 mods        mod  -     -                                                           2.0.1  nexus:19119:-:alt._colo,_-_gs
Zenitex_Armor_Pads            2.5 mods        mod  -     -                                                           4.1    nexus:12044:-:alt._colo,_-_gs
Zenitex_Panam_Pants           2.5 mods        mod  -     -                                                           4.0    nexus:10842:-:alt._colo,_-_gs
Zenitex_Combat_Gloves         2.5 mods        mod  -     -                                                           2.0.1  nexus:19432:-:alt._colo,garment_support
Comfy_Boots                   2.5 mods        mod  -     -                                                           1.1    nexus:11212:-:gymfiend
Vehicle_Pack_Basic_1          2.5 mods        mod  -     -                                                           1.8.2  nexus:4625:-:~car_pack_2
Vehicle_Pack_Basic_2          2.5 mods        mod  -     -                                                           1.9.0  nexus:4625:+car_pack_2
Cyberpunk_Bikes_Edge          2.5 mods        mod  -     -                                                           1.03   nexus:14719
Vehicle_Exit_Fix              2.5 mods        mod  -     -                                                           1.0    nexus:22786
Bikes_of_the_Dark_Future      2.5 mods        mod  -     -                                                           1.3    nexus:18736:+bdf_dre_archv4:mirrors,hypervelocity
Vehicle_Manufacturer_Fix      2.5 mods        mod  -     -                                                           1.0    nexus:28744
Toyota_Supra_HKS              2.5 mods        mod  -     -                                                           1.0.5  nexus:12652:+hks_widebody
Material_and_Texture_Override 2.5 mods        lib  -     -                                                           1.2    nexus:5266:-:redmod
Porsche_911_GT3_RS            2.5 mods        mod  -     -                                                           1.2    nexus:11180:+main_file
Vehicle_Customizer            2.5 mods        mod  -     -                                                           3.0    nexus:9034:+3dot0
Vehicle_Customizer_update     2.5 mods        mod  -     -                                                           3.1    nexus:9034:+3dot1
Deceptious_Quest_Core         2.5 mods        lib  -     -                                                           3.3.3  nexus:7831
VendorsXL                     2.5 mods        lib  -     -                                                           2.2.0  nexus:19679:+vendorsxl
Vehicle_Manufacturers_Resource 2.5 mods        lib  -     -                                                           1.1    nexus:7855
Equipment_EX                  2.5 eqex        mod  -     -                                                           1.2.10 nexus:6945:+equipment-ex
Impact_FX                     2.5 mods        mod  -     -                                                           0.8.3.3 nexus:36631
Immersive_Audio_Distance      2.5 mods        mod  -     -                                                           1.2.0  nexus:36809:+(2.5)
Apollo_Intensa_Emozione       2.5 mods        mod  -     -                                                           1      nexus:37233
Countach_LPI_800-4            2.5 mods        mod  -     -                                                           1      nexus:37234
Countach_Liberty_Walk         2.5 mods        mod  -     -                                                           1      nexus:37235
VAZ_Oka_Yozakura              2.5 mods        mod  -     -                                                           4      nexus:36381
Toyota_GR_Yaris               2.5 mods        mod  -     -                                                           3.3    nexus:34357:+all_purpose
Toyota_GR_Yaris_Rocket_Bunny  2.5 mods        mod  -     -                                                           3.2    nexus:34357:+rocket_bunny
Nissan_Silvia_S14             2.5 mods        mod  -     -                                                           1.1    nexus:25997:+main_files
Goliath_Coat                  2.5 mods        mod  -     -                                                           1.0.0  nexus:36516
Cityfolk_Hoodie               2.5 mods        mod  -     -                                                           1.0.2  nexus:37493
Knife_Bandolier               2.5 mods        mod  -     -                                                           1.0.2  nexus:26000
Bunny_Slippers                2.5 mods        mod  -     -                                                           1.0.1  nexus:26996
Saul_Pants                    2.5 mods        mod  -     -                                                           1.0.3  nexus:27128
CrystalJock_Bomber            2.5 mods        mod  -     -                                                           1.1.2  nexus:27304
Master_Chief_Suit             2.5 mods        mod  -     -                                                           1.1.0  nexus:33439
Indiana_Jones_Outfit          2.5 mods        mod  -     -                                                           1.0.0  nexus:34748
Fifth_Element_Collection      2.5 mods        mod  -     -                                                           1.1.0  nexus:27709:+all_in_one
Cityfolk_Short_Jacket         2.5 mods        mod  -     -                                                           1.2.0  nexus:27736
Jackies_Jacket                2.5 mods        mod  -     -                                                           1.0.0  nexus:31662
Stinky_Burnt_Top              2.5 mods        mod  -     -                                                           2.1.0  nexus:20042
Stinky_Slashed_Top            2.5 mods        mod  -     -                                                           2.1.0  nexus:12757
Stinky_Croptop                2.5 mods        mod  -     -                                                           1.1.0  nexus:26048
Yeehaw_Collar_Shirt           2.5 mods        mod  -     -                                                           1.3.0  nexus:26873
Chuckwalla_T-Shirt            2.5 mods        mod  -     -                                                           1.0.1  nexus:31111
Stinky_Mechanic_Pants         2.5 mods        mod  -     -                                                           2.0.2  nexus:16402
Stinky_Quilted_Pants          2.5 mods        mod  -     -                                                           1.0.1  nexus:26049
Stinky_Bootcut_Jeans          2.5 mods        mod  -     -                                                           1.0.1  nexus:26050
Stinky_Leather_Jeans          2.5 mods        mod  -     -                                                           1.0.1  nexus:26818
David_Martinez_Pants          2.5 mods        mod  -     -                                                           1.0.1  nexus:35536
Yeehaw_Spur_Boots             2.5 mods        mod  -     -                                                           1.0.1  nexus:26982
Latex_Succubus_Tail           2.5 mods        mod  -     -                                                           1.0.0  nexus:32638
Trauma_Team_Jumpsuit          2.5 mods        mod  -     -                                                           1.0.0  nexus:32329
Dexter_Pants                  2.5 mods        mod  -     -                                                           1.2.0  nexus:28660:+pants
Dexter_Vest                   2.5 mods        mod  -     -                                                           1.2.0  nexus:28660:+vest
Dexter_Shoes                  2.5 mods        mod  -     -                                                           1      nexus:28660:+shoes
PinkyBlume_Croptop            2.5 mods        mod  -     -                                                           1      nexus:27455
RVC00N_Dumpster_3             2.5 mods        mod  -     -                                                           21.0.0 nexus:25981
Street_Ninja_Remake           2.5 mods        mod  -     -                                                           1.14.0 nexus:36978:+main
Street_Ninja_Shop             2.5 mods        mod  -     -                                                           1.12.0 nexus:36978:+shop
AirPods_Max                   2.5 mods        mod  -     -                                                           1.1    nexus:28288
Nola_Barbed_Accessories       2.5 mods        mod  -     -                                                           1.0    nexus:14371
Nola_Bracelets                2.5 mods        mod  -     -                                                           1.0    nexus:16722
Nola_Heart_Choker             2.5 mods        mod  -     -                                                           1.1    nexus:11685
Nola_Mini_Dress               2.5 mods        mod  -     -                                                           1.1    nexus:15704
Nola_Moon_Accessories         2.5 mods        mod  -     -                                                           1.0    nexus:14324
Nola_Spiked_Collar            2.5 mods        mod  -     -                                                           1.1    nexus:14269
Nola_Accessories_Store        2.5 mods        mod  -     -                                                           1.8    nexus:14299
Zenitex_Combat_Armor          2.5 mods        mod  -     -                                                           3.3    nexus:13212:-:alt._colo,garment_support
Zenitex_FAST_Helmet           2.5 mods        mod  -     -                                                           3.4    nexus:13557:-:alt._colo,garment_support
Zenitex_Ballistic_Vest        2.5 mods        mod  -     -                                                           3.6    nexus:14348:-:alt._colo,alt._vest,alt._pouches,garment_support
Zenitex_Combat_Boots          2.5 mods        mod  -     -                                                           3.4    nexus:14781:-:alt._colo,garment_support
Zenitex_Pistol_Holsters       2.5 mods        mod  -     -                                                           1.5    nexus:18002:-:alt._colo,garment_support
Zenitex_Military_Backpack     2.5 mods        mod  -     -                                                           1.5    nexus:18152:-:alt._colo,garment_support
Zenitex_Military_Underwear    2.5 mods        mod  -     -                                                           1.5    nexus:20394:-:alt._colo,garment_support
Zenitex_Combat_Goggles        2.5 mods        mod  -     -                                                           1.4    nexus:17049:-:alt._colo,garment_support
Zenitex_Balaclava_Pack        2.5 mods        mod  -     -                                                           2.1    nexus:17411:-:alt._colo,_-_gs
Nola_Virtual_Boutique         2.5 mods        mod  -     -                                                           7.6    nexus:5114:+female
Preem_Hair                    2.5 mods        mod  -     -                                                           3.0.0  nexus:8223:+(2k)
Wolfcut_Messy                 2.5 mods        mod  -     -                                                           2.0    nexus:16697:+messy_wolfcut
Wolfcut_Emo                   2.5 mods        mod  -     -                                                           2.0    nexus:16697:+emo_wolfcut
Wolfcut_Hime_Short            2.5 mods        mod  -     -                                                           2.0    nexus:16697:+hime_short
Wolfcut_Hime_Medium           2.5 mods        mod  -     -                                                           2.0    nexus:16697:+hime_medium
Wolfcut_Hime_Long             2.5 mods        mod  -     -                                                           2.0    nexus:16697:+hime_long
Subleader_Hair_Pack           2.5 mods        mod  -     -                                                           1.09   nexus:19268:+allinone
Hyst_Hair_Collection          2.5 mods        mod  -     -                                                           1.2    nexus:21766:+all_in_one
Meluminary_Hair_Megapak       2.5 mods        mod  -     -                                                           5.0.0  nexus:19197:+megapak
Undercut_Slickback            2.5 mods        mod  -     -                                                           1.0    nexus:19907:+hair_01
Undercut_Sidewave             2.5 mods        mod  -     -                                                           1.0    nexus:19907:+hair_02
Undercut_ManBun               2.5 mods        mod  -     -                                                           1.0    nexus:19907:+hair_03
Undercut_Slickback_Braids     2.5 mods        mod  -     -                                                           1.1    nexus:19907:+hair_04
Bullet_Necklace               2.5 mods+eqex   mod  -     -                                                           1.1    nexus:15076
Chain_Jewelry                 2.5 mods+eqex   mod  -     -                                                           1.2    nexus:15861:+jewelry_-_main
Reyes_Accessories             2.5 mods+eqex   mod  -     -                                                           1.1    nexus:17069
raem_Accessory_Store          2.5 mods+eqex   mod  -     -                                                           2.0    nexus:14210:+accessories_-_main
"
# <<< add-on sets
# What a component needs besides RED4ext: without it, it is not installed (a store without
# Virtual Atelier would stop redscript from compiling every script, NightCoop's included).
# A component comes after what it needs in the table above.
# Phantom_Liberty is the game's expansion (archive/pc/ep1), not a component: without it, what needs
# it is left out.
ADDON_NEEDS="Let_There_Be_Flight:redscript,ArchiveXL,TweakXL,Input_Loader
Mod_Settings:redscript,ArchiveXL Audioware:redscript,Codeware,TweakXL Native_Settings_UI:Cyber_Engine_Tweaks
Virtual_Atelier:redscript,Codeware,ArchiveXL,Mod_Settings A.G.I.S.:Virtual_Atelier Night_City_Marketplace:Virtual_Atelier
Virtual_Car_Dealer:redscript,Codeware,ArchiveXL,TweakXL Quick_Stash:Cyber_Engine_Tweaks Cyber_Drift:Cyber_Engine_Tweaks
Drive_an_Aerial_Vehicle:redscript,Codeware,TweakXL,Cyber_Engine_Tweaks,Native_Settings_UI
All_Vanilla_Clothes:Virtual_Atelier Iconic_Shops:Virtual_Atelier,TweakXL Zenitex_Virtual_Atelier:Virtual_Atelier
Zenitex_Ballistic_Mask:ArchiveXL,TweakXL Zenitex_Tactical_Harness:ArchiveXL,TweakXL Zenitex_Combat_Jacket:ArchiveXL,TweakXL
Zenitex_Armor_Pads:ArchiveXL,TweakXL Zenitex_Panam_Pants:ArchiveXL,TweakXL Zenitex_Combat_Gloves:ArchiveXL,TweakXL
Comfy_Boots:ArchiveXL,TweakXL Vehicle_Pack_Basic_1:Virtual_Car_Dealer Vehicle_Pack_Basic_2:Virtual_Car_Dealer
Cyberpunk_Bikes_Edge:ArchiveXL,TweakXL Bikes_of_the_Dark_Future:ArchiveXL,TweakXL,Cyber_Engine_Tweaks,redscript,Vehicle_Exit_Fix
Toyota_Supra_HKS:ArchiveXL,TweakXL,Cyber_Engine_Tweaks,redscript,Vehicle_Manufacturer_Fix
Porsche_911_GT3_RS:ArchiveXL,TweakXL,Cyber_Engine_Tweaks,Material_and_Texture_Override,Virtual_Car_Dealer
Vehicle_Customizer:Cyber_Engine_Tweaks Vehicle_Customizer_update:Vehicle_Customizer
Deceptious_Quest_Core:ArchiveXL VendorsXL:redscript,Codeware,ArchiveXL,TweakXL,Deceptious_Quest_Core
Equipment_EX:redscript,Codeware,ArchiveXL,TweakXL Impact_FX:redscript,Codeware,TweakXL
Immersive_Audio_Distance:redscript,Codeware
Apollo_Intensa_Emozione:redscript,Codeware,ArchiveXL,TweakXL,Cyber_Engine_Tweaks,Virtual_Car_Dealer
Countach_LPI_800-4:redscript,Codeware,ArchiveXL,TweakXL,Cyber_Engine_Tweaks,Virtual_Car_Dealer
Countach_Liberty_Walk:redscript,Codeware,ArchiveXL,TweakXL,Cyber_Engine_Tweaks,Virtual_Car_Dealer
VAZ_Oka_Yozakura:redscript,Codeware,ArchiveXL,TweakXL,Cyber_Engine_Tweaks,Virtual_Car_Dealer
Toyota_GR_Yaris:ArchiveXL,TweakXL,Virtual_Car_Dealer Toyota_GR_Yaris_Rocket_Bunny:Toyota_GR_Yaris
Nissan_Silvia_S14:redscript,ArchiveXL,TweakXL,Vehicle_Manufacturers_Resource,Virtual_Car_Dealer
Goliath_Coat:ArchiveXL,TweakXL Cityfolk_Hoodie:ArchiveXL,TweakXL Knife_Bandolier:ArchiveXL,TweakXL
Bunny_Slippers:ArchiveXL,TweakXL Saul_Pants:ArchiveXL,TweakXL CrystalJock_Bomber:ArchiveXL,TweakXL
Master_Chief_Suit:ArchiveXL,TweakXL Indiana_Jones_Outfit:ArchiveXL,TweakXL
Fifth_Element_Collection:ArchiveXL,TweakXL Cityfolk_Short_Jacket:ArchiveXL,TweakXL
Jackies_Jacket:ArchiveXL,TweakXL Stinky_Burnt_Top:ArchiveXL,TweakXL Stinky_Slashed_Top:ArchiveXL,TweakXL
Stinky_Croptop:ArchiveXL,TweakXL Yeehaw_Collar_Shirt:ArchiveXL,TweakXL Chuckwalla_T-Shirt:ArchiveXL,TweakXL
Stinky_Mechanic_Pants:ArchiveXL,TweakXL Stinky_Quilted_Pants:ArchiveXL,TweakXL
Stinky_Bootcut_Jeans:ArchiveXL,TweakXL Stinky_Leather_Jeans:ArchiveXL,TweakXL
David_Martinez_Pants:ArchiveXL,TweakXL Yeehaw_Spur_Boots:ArchiveXL,TweakXL
Latex_Succubus_Tail:ArchiveXL,TweakXL Trauma_Team_Jumpsuit:ArchiveXL,TweakXL Dexter_Pants:ArchiveXL,TweakXL
Dexter_Vest:ArchiveXL,TweakXL Dexter_Shoes:ArchiveXL,TweakXL PinkyBlume_Croptop:ArchiveXL,TweakXL
RVC00N_Dumpster_3:Virtual_Atelier,ArchiveXL,TweakXL,VendorsXL Street_Ninja_Remake:redscript,Codeware,ArchiveXL,TweakXL
Street_Ninja_Shop:Virtual_Atelier,Cyber_Engine_Tweaks,Street_Ninja_Remake
AirPods_Max:ArchiveXL,TweakXL
Nola_Barbed_Accessories:ArchiveXL,TweakXL Nola_Bracelets:ArchiveXL,TweakXL Nola_Heart_Choker:ArchiveXL,TweakXL
Nola_Mini_Dress:ArchiveXL,TweakXL Nola_Moon_Accessories:ArchiveXL,TweakXL Nola_Spiked_Collar:ArchiveXL,TweakXL
Nola_Accessories_Store:Virtual_Atelier
Zenitex_Combat_Armor:ArchiveXL,TweakXL Zenitex_FAST_Helmet:ArchiveXL,TweakXL,Phantom_Liberty
Zenitex_Ballistic_Vest:ArchiveXL,TweakXL Zenitex_Combat_Boots:ArchiveXL,TweakXL
Zenitex_Pistol_Holsters:ArchiveXL,TweakXL,Phantom_Liberty Zenitex_Military_Backpack:ArchiveXL,TweakXL,Phantom_Liberty
Zenitex_Military_Underwear:ArchiveXL,TweakXL Zenitex_Combat_Goggles:ArchiveXL,TweakXL Zenitex_Balaclava_Pack:ArchiveXL,TweakXL
Nola_Virtual_Boutique:Virtual_Atelier Wolfcut_Messy:ArchiveXL Wolfcut_Emo:ArchiveXL Wolfcut_Hime_Short:ArchiveXL
Wolfcut_Hime_Medium:ArchiveXL Wolfcut_Hime_Long:ArchiveXL Subleader_Hair_Pack:ArchiveXL Hyst_Hair_Collection:ArchiveXL
Meluminary_Hair_Megapak:ArchiveXL Undercut_Slickback:ArchiveXL Undercut_Sidewave:ArchiveXL Undercut_ManBun:ArchiveXL
Undercut_Slickback_Braids:ArchiveXL Bullet_Necklace:ArchiveXL,TweakXL,Equipment_EX Chain_Jewelry:ArchiveXL,TweakXL,Equipment_EX
Reyes_Accessories:ArchiveXL,TweakXL,Equipment_EX raem_Accessory_Store:Virtual_Atelier"
# Outfit mods: in co-op, a partner without the same mod sees a plain game piece in their place.
OUTFITS="Zenitex_Ballistic_Mask Zenitex_Tactical_Harness Zenitex_Combat_Jacket Zenitex_Armor_Pads Zenitex_Panam_Pants
Zenitex_Combat_Gloves Comfy_Boots Goliath_Coat Cityfolk_Hoodie Knife_Bandolier Bunny_Slippers Saul_Pants CrystalJock_Bomber
Master_Chief_Suit Indiana_Jones_Outfit Fifth_Element_Collection Cityfolk_Short_Jacket Jackies_Jacket Stinky_Burnt_Top
Stinky_Slashed_Top Stinky_Croptop Yeehaw_Collar_Shirt Chuckwalla_T-Shirt Stinky_Mechanic_Pants Stinky_Quilted_Pants
Stinky_Bootcut_Jeans Stinky_Leather_Jeans David_Martinez_Pants Yeehaw_Spur_Boots Latex_Succubus_Tail Trauma_Team_Jumpsuit
Dexter_Pants Dexter_Vest Dexter_Shoes PinkyBlume_Croptop Street_Ninja_Remake AirPods_Max
Nola_Barbed_Accessories Nola_Bracelets Nola_Heart_Choker Nola_Mini_Dress Nola_Moon_Accessories
Nola_Spiked_Collar Zenitex_Combat_Armor Zenitex_FAST_Helmet Zenitex_Ballistic_Vest Zenitex_Combat_Boots
Zenitex_Pistol_Holsters Zenitex_Military_Backpack Zenitex_Military_Underwear Zenitex_Combat_Goggles Zenitex_Balaclava_Pack
Bullet_Necklace Chain_Jewelry Reyes_Accessories"
# Hairstyles added to the character creator: in co-op, a partner without the same mod sees no hair there.
HAIRS="Wolfcut_Messy Wolfcut_Emo Wolfcut_Hime_Short Wolfcut_Hime_Medium Wolfcut_Hime_Long Subleader_Hair_Pack
Hyst_Hair_Collection Meluminary_Hair_Megapak Undercut_Slickback Undercut_Sidewave Undercut_ManBun Undercut_Slickback_Braids"
# Files a mod writes to while the game runs (its settings, its database, what it has learned):
# the player's copy stays, and is replaced only when a new release changes the file it ships.
# "*" is every component; a "*" in a pattern also matches across folders.
#   component              file (relative to the game folder)
ADDON_STATE="
*                       bin/x64/plugins/cyber_engine_tweaks/mods/*/db.sqlite3
Cyber_Drift             bin/x64/plugins/cyber_engine_tweaks/mods/CyberDrift*/custom/*
Drive_an_Aerial_Vehicle bin/x64/plugins/cyber_engine_tweaks/mods/DriveAerialVehicle/Data/*
Vehicle_Customizer      bin/x64/plugins/cyber_engine_tweaks/mods/VehicleCustomizerSVE/*
"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nightcoop-linux"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nightcoop-linux"
BACKUP_ROOT="$DATA_DIR/backups"

MODE="install"
NIGHTCOOP_ZIP=""
RED4EXT_ZIP=""
VCREDIST=""
OPT_STEAM_ROOT=""
CLOSE_STEAM=0
PROTON_WANT="auto"
GAME_ARGS="--launcher-skip"
GP_OPT=""        # on or off: --game-performance, --no-game-performance (remembered in settings.tsv)
MH_OPT=""        # on or off: --mangohud, --no-mangohud
SAVE_BACKUP=""   # 1 or 0; empty: copy the saves on the first install only
SET_WANT=()      # +flight, -flight, +mods, -mods from the options; a set not named stays as it was
NEXUS_DIRS=()    # where to look for the Nexus downloads (--mods-from); default: the Downloads folder
FORCE=0
DRY_RUN=0
ASSUME_YES=0
RESTORE_DIR=""

# ----------------------------------------------------------- python helper ----
# Binary and structured-file work (PE version resources, Valve KeyValues files,
# Wine registry, zip archives, file manifests) lives here; bash drives the flow.
IFS= read -r -d '' PYHELPER <<'PY' || true
import calendar, filecmp, fnmatch, glob, hashlib, json, os, re, shutil, struct, sys, time, zipfile

SEP = '\x1f'
CRT_PREFIXES = ('msvcp140', 'vcruntime140', 'concrt140', 'vccorlib140')


def out(*fields):
    print(SEP.join('' if f is None else str(f) for f in fields))


def die(msg, code=2):
    sys.stderr.write(msg + '\n')
    sys.exit(code)


# ------------------------------------------------------------------ versions
def vtuple(v):
    m = re.search(r'\d+(?:\.\d+)*', re.sub(r'\s*,\s*', '.', str(v or '')))
    return [int(x) for x in m.group(0).split('.')] if m else []


def vcmp(a, b):
    x, y = vtuple(a), vtuple(b)
    n = max(len(x), len(y))
    x, y = x + [0] * (n - len(x)), y + [0] * (n - len(y))
    return (x > y) - (x < y)


def norm_game(v):
    """'2.5', '2.50', '2.5.0' and '2.5.0.0' all become '2.5'."""
    m = re.search(r'\d+(?:\.\d+)*', str(v or ''))
    if not m:
        return str(v or '').strip().lower()
    parts = m.group(0).split('.')
    while len(parts) > 1 and not parts[-1].strip('0'):
        parts.pop()
    if len(parts) > 1:
        parts[-1] = parts[-1].rstrip('0')
    return '.'.join(parts)


# ----------------------------------------------------------------- PE files
class PE:
    def __init__(self, path):
        self.f = f = open(path, 'rb')
        try:
            mz = f.read(64)
            if len(mz) < 64 or mz[:2] != b'MZ':
                raise ValueError('not a PE file')
            f.seek(struct.unpack_from('<I', mz, 0x3c)[0])
            h = f.read(24)
            if len(h) < 24 or h[:4] != b'PE\0\0':
                raise ValueError('not a PE file')
            nsec, = struct.unpack_from('<H', h, 6)
            optsz, = struct.unpack_from('<H', h, 20)
            opt = f.read(optsz)
            base = {0x20b: 112, 0x10b: 96}.get(struct.unpack_from('<H', opt, 0)[0])
            if base is None:
                raise ValueError('unknown optional header')
            self.linker = '%d.%d' % (opt[2], opt[3])
            self.dirs = [struct.unpack_from('<II', opt, base + 8 * i)
                         for i in range(16) if base + 8 * i + 8 <= len(opt)]
            st = f.read(40 * nsec)
            self.secs = [struct.unpack_from('<IIII', st, 40 * i + 8) for i in range(nsec)]
        except Exception:
            f.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.f.close()

    def dir(self, i):
        return self.dirs[i] if i < len(self.dirs) else (0, 0)

    def read(self, rva, n):
        for vsz, va, rsz, rptr in self.secs:
            if va <= rva < va + max(vsz, rsz):
                self.f.seek(rptr + rva - va)
                return self.f.read(n)
        return b''

    def imports(self):
        rva, names = self.dir(1)[0], []
        while rva and len(names) < 1024:
            e = self.read(rva, 20)
            if len(e) < 20 or not any(e):
                break
            names.append(self.read(struct.unpack_from('<I', e, 12)[0], 256).split(b'\0', 1)[0].decode('latin-1'))
            rva += 20
        return names

    def version_data(self):
        base = self.dir(2)[0]
        if not base:
            return b''

        def entries(off):
            h = self.read(base + off, 16)
            if len(h) < 16:
                return []
            nn, ni = struct.unpack_from('<HH', h, 12)
            raw = self.read(base + off + 16, 8 * (nn + ni))
            return [struct.unpack_from('<II', raw, 8 * k) for k in range(len(raw) // 8)]

        node = next((off for name, off in entries(0) if name == 16), None)   # RT_VERSION
        for _ in range(2):                                                     # name, language
            if node is None or not node & 0x80000000:
                return b''
            sub = entries(node & 0x7fffffff)
            node = sub[0][1] if sub else None
        if node is None or node & 0x80000000:
            return b''
        rva, size = struct.unpack_from('<II', self.read(base + node, 8))
        return self.read(rva, size)

    def version_info(self):
        data, fixed, strings = self.version_data(), None, {}

        def walk(off, end, depth):
            nonlocal fixed
            while off + 6 <= end:
                wlen, vlen, _ = struct.unpack_from('<HHH', data, off)
                if wlen < 6:
                    break
                bend = min(off + wlen, end)
                k = off + 6
                while k + 1 < bend and data[k:k + 2] != b'\0\0':
                    k += 2
                key = data[off + 6:k].decode('utf-16le', 'replace')
                v = (k + 2 + 3) & ~3
                if depth == 0:
                    if vlen >= 52 and data[v:v + 4] == b'\xbd\x04\xef\xfe':
                        fixed = data[v:v + 52]
                    walk((v + vlen + 3) & ~3, bend, 1)
                elif depth == 1:
                    if key == 'StringFileInfo':
                        walk(v, bend, 2)
                elif depth == 2:
                    walk(v, bend, 3)
                else:
                    strings.setdefault(key, data[v:bend].decode('utf-16le', 'replace').split('\0', 1)[0].strip())
                off = (off + wlen + 3) & ~3

        if data:
            walk(0, len(data), 0)
        return fixed, strings


def fixed_version(fixed, kind):
    ms, ls = struct.unpack_from('<II', fixed, 16 if kind == 'product' else 8)
    return '%d.%d.%d.%d' % (ms >> 16, ms & 0xffff, ls >> 16, ls & 0xffff)


def scan_version(path, kind):
    """Last resort for an unusual resource layout: find the string anywhere."""
    with open(path, 'rb') as fh:
        data = fh.read()
    key = ('ProductVersion' if kind == 'product' else 'FileVersion').encode('utf-16le') + b'\0\0'
    i = data.find(key)
    if i < 0:
        return ''
    i += len(key)
    while data[i:i + 2] == b'\0\0':
        i += 2
    j = i
    while j + 1 < len(data) and data[j:j + 2] != b'\0\0':
        j += 2
    return data[i:j].decode('utf-16le', 'ignore').strip()


def pe_info(path):
    try:
        with PE(path) as pe:
            return pe.version_info()
    except (OSError, ValueError, struct.error):
        return None, {}


def pe_version(path, kind):
    fixed, strings = pe_info(path)
    s = strings.get('ProductVersion' if kind == 'product' else 'FileVersion', '')
    m = re.match(r'\s*(\d+(?:\s*[.,]\s*\d+)*)', s)   # "14.29.30157.0 built by: cloudtest" -> 14.29.30157.0
    if m:
        return re.sub(r'\s*[.,]\s*', '.', m.group(1))
    if fixed:
        return fixed_version(fixed, kind)
    try:
        return scan_version(path, kind)
    except OSError:
        return ''


def cmd_pever(path, kind='file'):
    out(pe_version(path, kind))


def game_label(fixed):
    """CDPR's patch name from the fixed product version, as RED4ext reads it:
    2.3.1 is patch 2.31, 2.5.0 is 2.5, 2.1.2 is 2.12."""
    ms, ls = struct.unpack_from('<II', fixed, 16)
    major, minor, patch = (ms >> 16) & 0xff, ms & 0xffff, ls >> 16
    return '%d.%d%s' % (major, minor, patch or '') if major else ''


def cmd_gamever(path):
    """patch name (2.31), product version string, file version (3.0.80.51928)."""
    fixed, _ = pe_info(path)
    label = game_label(fixed) if fixed else ''
    out(label or norm_game(pe_version(path, 'product')), pe_version(path, 'product'),
        fixed_version(fixed, 'file') if fixed else '')


def cmd_r4ok(r4ver, gamefile, table):
    """Exit 0 if RED4ext r4ver runs on the game with file version gamefile.
    table: 'R4VER:GAMEFILEVER ...', each RED4ext release and the game build it requires.
    Every release refuses older games and targets one patch, so a game needs the newest
    release whose game build it has reached, or a later one."""
    rows = sorted(((r, g) for r, _, g in (x.partition(':') for x in table.split())), key=lambda x: vtuple(x[0]))
    if not gamefile:
        sys.exit(0)
    needs = [g for r, g in rows if vcmp(r, r4ver) <= 0]            # builds r4ver's line requires
    if needs and vcmp(gamefile, needs[-1]) < 0:
        sys.exit(1)                                                 # game too old for this RED4ext
    floor = [r for r, g in rows if vcmp(gamefile, g) >= 0]          # releases this game has reached
    sys.exit(1 if floor and vcmp(r4ver, floor[-1]) < 0 else 0)      # too old for this game


def cmd_pestr(path, key):
    out(pe_info(path)[1].get(key, ''))


def cmd_vge(a, b):
    sys.exit(0 if vcmp(a, b) >= 0 else 1)


def cmd_builtin(path):
    """Exit 0 if a prefix DLL is one of Wine's own (a link into Proton or the builtin marker)."""
    if os.path.islink(path) and '/lib/wine/' in os.readlink(path):
        sys.exit(0)
    try:
        with open(path, 'rb') as fh:
            sys.exit(0 if b'Wine builtin DLL' in fh.read(4096) else 1)
    except OSError:
        sys.exit(1)


def cmd_pecrt(top, *extra):
    """Newest MSVC toolset among the DLLs that link the C++ runtime dynamically."""
    files = [p for p in extra if os.path.isfile(p)]
    for dp, _, fns in os.walk(top):
        files += [os.path.join(dp, f) for f in fns if f.lower().endswith(('.dll', '.asi'))]
    best = who = ''
    for p in files:
        try:
            with PE(p) as pe:
                if any(n.lower().startswith(CRT_PREFIXES) for n in pe.imports()) and \
                        (not best or vcmp(pe.linker, best) > 0):
                    best, who = pe.linker, os.path.basename(p)
        except (OSError, ValueError, struct.error):
            pass
    out(best, who)


# ------------------------------------------------- Valve KeyValues (VDF) text
TOK = re.compile(r'"((?:[^"\\]|\\.)*)"|([{}])|(//[^\n]*)|([^\s{}"]+)')


def unesc(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def vdf_parse(text):
    root = []
    stack, key = [root], None
    for m in TOK.finditer(text):
        q, br, com, bare = m.groups()
        if com is not None:
            continue
        if br == '{':
            node = []
            stack[-1].append((key or '', node))
            stack.append(node)
            key = None
        elif br == '}':
            if len(stack) > 1:
                stack.pop()
            key = None
        else:
            s = unesc(q) if q is not None else bare
            if key is None:
                key = s
            else:
                stack[-1].append((key, s))
                key = None
    return root


def vdf_load(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            return vdf_parse(fh.read())
    except OSError:
        return []


def vget(node, *path):
    for p in path:
        if not isinstance(node, list):
            return None
        node = next((v for k, v in node if k.lower() == str(p).lower()), None)
        if node is None:
            return None
    return node


# ------------------------------------------------------- Steam and Proton
def translate(p, root, kind):
    """Host paths for a path Steam wrote: Flatpak sandbox and pressure-vessel views."""
    home, cands = os.path.expanduser('~'), []
    if kind == 'flatpak':
        for pre in (home + '/.local/share/Steam', home + '/.steam/steam', home + '/.steam/root'):
            if p == pre or p.startswith(pre + '/'):
                cands.append(root + p[len(pre):])
                break
    cands.append(p)
    if p.startswith('/run/host/'):
        cands.append(p[len('/run/host'):])
    return cands


def cmd_libs(root, kind, appid):
    libs, seen = [], set()

    def add(p):
        rp = os.path.realpath(p)
        if rp not in seen and os.path.isdir(os.path.join(rp, 'steamapps')):
            seen.add(rp)
            libs.append(rp)

    add(root)
    for rel in ('steamapps/libraryfolders.vdf', 'config/libraryfolders.vdf'):
        lf = vget(vdf_load(os.path.join(root, rel)), 'libraryfolders')
        for _, v in lf if isinstance(lf, list) else []:
            path = vget(v, 'path') if isinstance(v, list) else v
            if isinstance(path, str) and path.startswith('/'):
                for c in translate(path, root, kind):
                    if os.path.isdir(os.path.join(c, 'steamapps')):
                        add(c)
                        break
    for lib in libs:
        inst = vget(vdf_load(os.path.join(lib, 'steamapps', 'appmanifest_%s.acf' % appid)), 'AppState', 'installdir')
        out(lib, inst if isinstance(inst, str) else '')


def proton_ok(d):
    return bool(d) and os.path.isfile(os.path.join(d, 'proton'))


MAPPING_PATH = ('installconfigstore', 'software', 'valve', 'steam', 'compattoolmapping')
VALVE_LABELS = {'proton_experimental': 'Proton Experimental', 'proton_hotfix': 'Proton Hotfix'}


def compat_names(root, appid):
    """(tool chosen for this game, Steam's default tool) from config.vdf; '' when unset."""
    m = vget(vdf_load(os.path.join(root, 'config', 'config.vdf')), *MAPPING_PATH)
    names = [vget(m, key, 'name') for key in (appid, '0')]
    return [n if isinstance(n, str) else '' for n in names]


def compat_setting(root, appid):
    app, default = compat_names(root, appid)
    return app or default


def official_name(dirname):
    """Steam's internal name for one of Valve's Proton folders: 'Proton 10.0' is proton_10."""
    if dirname == 'Proton - Experimental':
        return 'proton_experimental'
    if dirname == 'Proton Hotfix':
        return 'proton_hotfix'
    m = re.fullmatch(r'Proton (\d+)\.(\d+)', dirname)
    if not m:
        return ''
    major, minor = m.groups()
    return 'proton_%s' % major if minor == '0' and int(major) >= 7 else 'proton_%s%s' % (major, minor)


def discover_tools(root, libs):
    """Every installed Proton build: {internal name (lower case): (internal name, folder, label)}."""
    home, found = os.path.expanduser('~'), {}
    for td in (os.path.join(root, 'compatibilitytools.d'), os.path.join(home, '.steam', 'root', 'compatibilitytools.d'),
               '/usr/share/steam/compatibilitytools.d', '/usr/local/share/steam/compatibilitytools.d'):
        for d in sorted(glob.glob(os.path.join(td, '*'))):
            ct = vget(vdf_load(os.path.join(d, 'compatibilitytool.vdf')), 'compatibilitytools', 'compat_tools')
            for name, spec in ct if isinstance(ct, list) else []:
                ip, label = vget(spec, 'install_path'), vget(spec, 'display_name')
                p = os.path.normpath(os.path.join(d, ip if isinstance(ip, str) and ip else '.'))
                if proton_ok(p):
                    found.setdefault(name.lower(), (name, p, label if isinstance(label, str) and label else name))
            if proton_ok(d):
                found.setdefault(os.path.basename(d).lower(), (os.path.basename(d), d, os.path.basename(d)))
    for lib in libs:
        for d in sorted(glob.glob(os.path.join(lib, 'steamapps', 'common', '*'))):
            name = official_name(os.path.basename(d))
            if name and proton_ok(d):
                found.setdefault(name, (name, d, os.path.basename(d).replace(' - ', ' ')))
    return found


def cmd_ct_get(root, appid):
    out(*compat_names(root, appid))


def cmd_ct_list(root, *libs):
    for _, (name, d, label) in sorted(discover_tools(root, libs).items()):
        out(name, d, label)


def cmd_ct_pick(root, want, os_family, *libs):
    """The compatibility tool to set: want is auto, keep, experimental, cachyos, ge or a tool name.
    Prints: name, folder (empty when Steam still has to download it), reason."""
    tools = discover_tools(root, libs)
    current = compat_names(root, '1091500')[0]

    def newest(pattern):
        hits = [v for k, v in tools.items() if re.match(pattern, k)]
        return max(hits, key=lambda v: (vtuple(v[0]) or [0], v[0])) if hits else None

    def cachyos():   # the Steam Linux Runtime build mirrors Valve's environment most closely
        return newest(r'proton-cachyos.*slr') or newest(r'proton-cachyos')

    if want == 'keep':
        return
    def emit(hit, name, reason):
        out(hit[0] if hit else name, hit[1] if hit else '', reason, hit[2] if hit else VALVE_LABELS.get(name, name))

    if want == 'auto':
        if current and (current.lower() in tools or re.fullmatch(r'proton_(experimental|hotfix|\d+)', current)):
            emit(tools.get(current.lower()), current, 'already chosen for this game in Steam')
            return
        hit = cachyos() if os_family == 'cachyos' else None
        if hit:
            emit(hit, '', 'CachyOS\'s own Proton build')
            return
        want = 'experimental'
    if want == 'experimental':
        emit(tools.get('proton_experimental'), 'proton_experimental', 'Valve\'s Proton with the newest fixes')
    elif want == 'cachyos':
        hit = cachyos()
        if not hit:
            die('no proton-cachyos build is installed (sudo pacman -S proton-cachyos-slr)', 3)
        emit(hit, '', 'requested')
    elif want == 'ge':
        hit = newest(r'ge-proton')
        if not hit:
            die('no GE-Proton build is installed (it goes in ~/.local/share/Steam/compatibilitytools.d)', 3)
        emit(hit, '', 'requested')
    else:
        hit = tools.get(want.lower())
        if not hit and not re.fullmatch(r'proton_(experimental|hotfix|\d+)', want):
            die('no compatibility tool named %r is installed; installed: %s' %
                (want, ', '.join(sorted(v[0] for v in tools.values())) or 'none'), 3)
        emit(hit, want, 'requested')


def vdf_index(text):
    """Positions in a KeyValues text: {block path: [after '{', at '}']}, {value path: (start, end, value)}."""
    blocks, values, stack, key = {}, {}, [], None
    for m in TOK.finditer(text):
        q, br, com, bare = m.groups()
        if com is not None:
            continue
        if br == '{':
            stack.append((key or '').lower())
            key = None
            blocks.setdefault(tuple(stack), [m.end(), None])
        elif br == '}':
            if stack:
                b = blocks.get(tuple(stack))
                if b and b[1] is None:
                    b[1] = m.start()
                stack.pop()
            key = None
        else:
            s = q if q is not None else bare
            if key is None:
                key = s
            else:
                values.setdefault(tuple(stack) + (key.lower(),), (m.start(), m.end(), unesc(s)))
                key = None
    return blocks, values


def vdf_insert(text, at, depth, lines):
    """Insert KeyValues lines on the line after position at, indented with tabs like Steam."""
    nl = text.find('\n', at)
    nl = len(text) if nl < 0 else nl
    body = ''.join('\t' * (depth + d) + s + '\n' for d, s in lines)
    return text[:nl + 1] + body + text[nl + 1:]


def cmd_ct_set(root, appid, name):
    """Choose the compatibility tool for one game, as Steam's Properties > Compatibility does."""
    path = os.path.join(root, 'config', 'config.vdf')
    text = read_text(path)
    blocks, values = vdf_index(text)
    entry = MAPPING_PATH + (appid,)
    q = '"%s"' % esc(name)
    if entry in blocks:
        old = values.get(entry + ('name',))
        if old and old[2] == name:
            out('unchanged')
            return
        if old:
            text = text[:old[0]] + q + text[old[1]:]
        else:
            text = vdf_insert(text, blocks[entry][0], len(entry), [(0, '"name"\t\t' + q)])
    else:
        rows = [(0, '"%s"' % appid), (0, '{'), (1, '"name"\t\t' + q), (1, '"config"\t\t""'),
                (1, '"priority"\t\t"250"'), (0, '}')]
        if MAPPING_PATH in blocks:
            text = vdf_insert(text, blocks[MAPPING_PATH][0], len(MAPPING_PATH), rows)
        elif MAPPING_PATH[:-1] in blocks:
            rows = [(0, '"CompatToolMapping"'), (0, '{')] + [(d + 1, s) for d, s in rows] + [(0, '}')]
            text = vdf_insert(text, blocks[MAPPING_PATH[:-1]][0], len(MAPPING_PATH) - 1, rows)
        else:
            die('Steam\'s config.vdf has no InstallConfigStore > Software > Valve > Steam section', 3)
    shutil.copy2(path, path + '.nightcoop-backup-' + time.strftime('%Y%m%d-%H%M%S'))
    write_text(path, text)
    out('written')


def cmd_proton(root, kind, compat, appid, *libs):
    # 1. the Proton that last ran this prefix
    ci = os.path.join(compat, 'config_info') if compat else ''
    if ci and os.path.isfile(ci):
        with open(ci, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                m = re.match(r'\s*(/.+?)/(?:files|dist)/', line)
                for c in translate(m.group(1), root, kind) if m else []:
                    if proton_ok(c):
                        out(c, 'the prefix\'s last launch')
                        return
    # 2. the compatibility tool chosen in Steam
    tools = discover_tools(root, libs)
    name = compat_setting(root, appid)
    if name and name.lower() in tools:
        out(tools[name.lower()][1], 'Steam setting "%s"' % name)
        return
    # 3. best guess: Proton Experimental, then the newest of Valve's releases, then anything else
    valve = sorted((v for k, v in tools.items() if k.startswith('proton_')),
                   key=lambda v: (v[0] == 'proton_experimental', vtuple(v[0]) or [0]), reverse=True)
    order = valve + [v for k, v in sorted(tools.items()) if not k.startswith('proton_')]
    if order:
        out(order[0][1], 'best guess')


def cmd_slr(proton_dir, *libs):
    """_v2-entry-point of the Steam Linux Runtime the Proton build asks for, if any."""
    req = vget(vdf_load(os.path.join(proton_dir, 'toolmanifest.vdf')), 'manifest', 'require_tool_appid')
    if not isinstance(req, str) or not req:
        return
    known = {'1628350': 'SteamLinuxRuntime_sniper', '1391110': 'SteamLinuxRuntime_soldier'}
    for lib in libs:
        inst = vget(vdf_load(os.path.join(lib, 'steamapps', 'appmanifest_%s.acf' % req)), 'AppState', 'installdir')
        for n in [x for x in (inst if isinstance(inst, str) else '', known.get(req, '')) if x]:
            ep = os.path.join(lib, 'steamapps', 'common', n, '_v2-entry-point')
            if os.access(ep, os.X_OK):
                out(ep)
                return


# ---------------------------------------------------- Steam launch options
WDO = re.compile(r'''(?<![\w$])WINEDLLOVERRIDES=("[^"]*"|'[^']*'|[^\s"']*)''')
APPS_PATH = ['userlocalconfigstore', 'software', 'valve', 'steam', 'apps']


def dll_names(spec):
    return [n.strip().lower()[:-4] if n.strip().lower().endswith('.dll') else n.strip().lower() for n in spec.split(',')]


def wdo_modes(s):
    """The WINEDLLOVERRIDES match in a launch option line and {dll: load order} from it."""
    m, modes = WDO.search(s or ''), {}
    for e in m.group(1).strip('"\'').split(';') if m else []:
        names, _, md = e.partition('=')
        for n in dll_names(names):
            if n:
                modes.setdefault(n, md.strip().lower())
    return m, modes


# The words before %command%: VARIABLE=value settings, then wrappers. A quoted value is one word.
LO_WORD = re.compile(r'''(?:[^\s"']+|"[^"]*"|'[^']*')+''')


def lo_prefix(s):
    i = (s or '').find('%command%')
    return [m.group(0) for m in LO_WORD.finditer(s[:i])] if i >= 0 else []


def lo_name(w):
    """A wrapper's program name; nothing for a VARIABLE=value setting."""
    return '' if re.match(r'[A-Za-z_][A-Za-z0-9_]*=', w) else os.path.basename(w.replace('"', '').replace("'", ''))


def lo_uses(s):
    """The wrappers the script manages that a launch option line runs: game-performance,
    mangohud (the wrapper) and MANGOHUD=1 (the variable that turns on MangoHud's layer); and
    gamescope, in which MangoHud's own overlay is not supported."""
    used = []
    for w in lo_prefix(s):
        n = 'MANGOHUD=1' if re.fullmatch(r'''MANGOHUD=(1|"1"|'1')''', w) else lo_name(w)
        if n in ('game-performance', 'mangohud', 'MANGOHUD=1', 'gamescope') and n not in used:
            used.append(n)
    return used


def lo_build(dlls='winmm', args='', wrap=''):
    """The whole launch option line the script writes: the DLL overrides native-first, MANGOHUD=1 and
    game-performance when wished (game-performance right before %command%, CachyOS's order), %command%
    and the game arguments. It replaces what was there."""
    wishes = [w for w in wrap.split(',') if w]
    words = ['WINEDLLOVERRIDES="%s=n,b"' % ','.join(d for d in dlls.split(',') if d)]
    if '+mangohud' in wishes:
        words.append('MANGOHUD=1')
    if '+game-performance' in wishes:
        words.append('game-performance')
    return ' '.join(words + ['%command%'] + args.split())


def lo_state(s, dlls='winmm', args='', wrap=''):
    """ok: the line is the one the script writes (lo_build); broken: the DLL override sits after
    %command% (Steam passes it to the game as an argument); missing: anything else."""
    s = (s or '').strip()
    if ' '.join(s.split()) == lo_build(dlls, args, wrap):
        return 'ok'
    m, _ = wdo_modes(s)
    if m and '%command%' in s and m.start() > s.index('%command%'):
        return 'broken'
    return 'missing'


def lo_merge(s, dlls='winmm', args='', wrap=''):
    """The line to write: the script's own (lo_build). Other variables, wrappers and arguments that
    were there are not kept: the script writes the whole line."""
    return lo_build(dlls, args, wrap)


def lo_files(root):
    files = glob.glob(os.path.join(root, 'userdata', '*', 'config', 'localconfig.vdf'))
    recent = ''
    users = vget(vdf_load(os.path.join(root, 'config', 'loginusers.vdf')), 'users')
    for sid, u in users if isinstance(users, list) else []:
        if isinstance(u, list) and vget(u, 'MostRecent') == '1' and sid.isdigit():
            recent = str(int(sid) - 76561197960265728)
    files.sort(key=lambda f: (f.split(os.sep)[-3] != recent, f))
    return files


def lo_scan(text, appid):
    stack, key = [], None
    apps_open = app_open = lo = None
    for m in TOK.finditer(text):
        q, br, com, bare = m.groups()
        if com is not None:
            continue
        if br == '{':
            stack.append((key or '').lower())
            key = None
            if stack == APPS_PATH and apps_open is None:
                apps_open = m.end()
            if stack == APPS_PATH + [appid] and app_open is None:
                app_open = m.end()
        elif br == '}':
            if stack:
                stack.pop()
            key = None
        else:
            s = q if q is not None else bare
            if key is None:
                key = s
            else:
                if lo is None and stack == APPS_PATH + [appid] and key.lower() == 'launchoptions':
                    lo = (m.start(), m.end(), unesc(s))
                key = None
    return apps_open, app_open, lo


def read_text(path):
    with open(path, encoding='utf-8', errors='surrogateescape') as fh:
        return fh.read()


def write_text(path, text):
    tmp = path + '.nightcoop-tmp'
    with open(tmp, 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.write(text)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def cmd_lo_status(root, appid, dlls='winmm', args='', wrap=''):
    """state of the full wish (dlls, args and wrappers), current line, state of the winmm override alone."""
    files = lo_files(root)
    if not files:
        out('nofile', '', 'nofile')
        return
    lo = lo_scan(read_text(files[0]), appid)[2]
    cur = lo[2] if lo else ''
    out(lo_state(cur, dlls, args, wrap), cur, lo_state(cur))


def cmd_lo_merge(s, dlls='winmm', args='', wrap=''):
    out(lo_state(s, dlls, args, wrap), lo_merge(s, dlls, args, wrap))


def cmd_lo_uses(s):
    print(' '.join(lo_uses(s)))


def cmd_lo_set(root, appid, dlls='winmm', args='', wrap=''):
    for f in lo_files(root):
        text = read_text(f)
        apps_open, app_open, lo = lo_scan(text, appid)
        cur = lo[2] if lo else ''
        if lo_state(cur, dlls, args, wrap) == 'ok':
            out(f, 'already set')
            continue
        new = lo_merge(cur, dlls, args, wrap)
        if lo:
            text = text[:lo[0]] + '"' + esc(new) + '"' + text[lo[1]:]
        else:
            at = app_open if app_open is not None else apps_open
            if at is None:
                out(f, 'skipped (no apps section)')
                continue
            nl = text.find('\n', at)
            nl = len(text) if nl < 0 else nl
            indent = re.match(r'[ \t]*', text[nl + 1:]).group(0) or '\t'
            if app_open is not None:
                block = indent + '"LaunchOptions"\t\t"' + esc(new) + '"\n'
            else:
                block = (indent + '"' + appid + '"\n' + indent + '{\n' + indent + '\t"LaunchOptions"\t\t"' +
                         esc(new) + '"\n' + indent + '}\n')
            text = text[:nl + 1] + block + text[nl + 1:]
        shutil.copy2(f, f + '.nightcoop-backup-' + time.strftime('%Y%m%d-%H%M%S'))
        write_text(f, text)
        out(f, new)


# ------------------------------------------------------ NightCoop releases
def cmd_pick(path, gamevers, site, local_sha=''):
    try:
        with open(path, encoding='utf-8') as fh:
            d = json.load(fh)
        allrels = [r for r in d.get('releases', []) if isinstance(r, dict) and r.get('version')]
    except (OSError, ValueError, AttributeError) as e:
        out('error', str(e).replace('\n', ' '))
        return
    gvs = {norm_game(g) for g in gamevers.split(',') if g.strip()}

    def games(x):
        g = x.get('game') or []
        return [g] if isinstance(g, str) else [str(i) for i in g]

    def fits(x):
        return any(norm_game(g) in gvs for g in games(x))

    def mods(r):
        return [f for f in r.get('files') or [] if isinstance(f, dict) and f.get('url') and f.get('kind', 'mod') == 'mod']

    def url_of(f):
        u = str(f['url'])
        return u if re.match(r'^[a-z]+://', u) else site.rstrip('/') + '/' + u.lstrip('/')

    def emit(status, r, f):
        f = f or {}
        fits_file = fits(f) or (not games(f) and fits(r))
        out(status, r.get('version'), url_of(f) if f.get('url') else '', f.get('sha256', ''),
            ','.join(games(f) or games(r)), r.get('protocol', ''), f.get('red4ext', ''),
            1 if fits_file else 0, 1 if r.get('yanked') else 0)

    if local_sha:
        for r in allrels:
            for f in mods(r):
                if str(f.get('sha256', '')).lower() == local_sha.lower():
                    emit('match', r, f)
                    return
    rels = [r for r in allrels if not r.get('yanked')]
    if not rels:
        out('none')
        return
    pick = next((r for r in rels if fits(r) or any(fits(f) for f in mods(r))), rels[0])
    ms = mods(pick)
    f = next((x for x in ms if fits(x)), None) or next((x for x in ms if not games(x)), None) or (ms[0] if ms else None)
    emit('ok', pick, f)


# ------------------------------------------------------------ Wine registry
def reg_header(key):
    return '[' + key.replace('\\', '\\\\') + ']'


def reg_load(path):
    with open(path, 'rb') as fh:
        return fh.read().decode('latin-1').split('\n')


def reg_save(path, lines):
    tmp = path + '.nightcoop-tmp'
    with open(tmp, 'wb') as fh:
        fh.write('\n'.join(lines).encode('latin-1'))
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def reg_find(lines, key, name):
    hdr = reg_header(key).lower()
    for i, line in enumerate(lines):
        low = line.lower()
        if low.startswith(hdr) and (len(low) == len(hdr) or low[len(hdr)] in ' \t'):
            j = i + 1
            while j < len(lines) and not lines[j].startswith('['):
                j += 1
            pre = '"' + name.lower() + '"='
            k = next((x for x in range(i + 1, j) if lines[x].lower().startswith(pre)), None)
            return i, j, k
    return None, None, None


def reg_quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def cmd_reg_get(path, key, name):
    try:
        lines = reg_load(path)
    except OSError:
        sys.exit(1)
    _, _, k = reg_find(lines, key, name)
    if k is None:
        sys.exit(1)
    v = lines[k].split('=', 1)[1]
    if v.startswith('"') and v.endswith('"'):
        v = re.sub(r'\\(.)', r'\1', v[1:-1])
    out(v)


def cmd_reg_set(path, key, name, value):
    lines = reg_load(path)
    i, j, k = reg_find(lines, key, name)
    entry = reg_quote(name) + '=' + reg_quote(value)
    if k is not None:
        lines[k] = entry
    elif i is not None:
        at = i + 1
        while at < j and lines[at].startswith('#'):
            at += 1
        lines.insert(at, entry)
    else:
        while lines and lines[-1] == '':
            lines.pop()
        now = int(time.time())
        lines += ['', '%s %d' % (reg_header(key), now), '#time=%x' % ((now + 11644473600) * 10000000), entry, '']
    reg_save(path, lines)


def cmd_reg_del(path, key, name):
    lines = reg_load(path)
    _, _, k = reg_find(lines, key, name)
    if k is not None:
        del lines[k]
        reg_save(path, lines)


def cmd_wsrv(pfx):
    """PIDs of wineserver processes serving this prefix."""
    target = os.path.realpath(pfx)
    for pid in filter(str.isdigit, os.listdir('/proc')):
        try:
            with open('/proc/%s/comm' % pid) as fh:
                if fh.read().strip() != 'wineserver':
                    continue
            with open('/proc/%s/environ' % pid, 'rb') as fh:
                env = fh.read().split(b'\0')
        except OSError:
            continue
        for e in env:
            if e.startswith(b'WINEPREFIX=') and os.path.realpath(e[11:].decode(errors='replace')) == target:
                print(pid)


# ---------------------------------------------------- archives and folders
def cmd_unzip(zpath, dest):
    try:
        z = zipfile.ZipFile(zpath)
    except (zipfile.BadZipFile, OSError) as e:
        die('not a usable zip archive: %s (%s)' % (zpath, e))
    with z:
        for info in z.infolist():
            name = info.filename.replace('\\', '/')
            parts = [p for p in name.split('/') if p not in ('', '.')]
            if name.startswith('/') or re.match(r'^[A-Za-z]:', name) or '..' in parts:
                die('refusing unsafe path in archive: ' + info.filename)
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                die('refusing symbolic link in archive: ' + info.filename)
            if not parts:
                continue
            target = os.path.join(dest, *parts)
            if name.endswith('/'):
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            try:
                with z.open(info) as src, open(target, 'wb') as dst:
                    shutil.copyfileobj(src, dst)
            except (RuntimeError, zipfile.BadZipFile, NotImplementedError) as e:
                die('cannot extract %s: %s' % (info.filename, e))
            t = time.mktime(info.date_time + (0, 0, -1))
            os.utime(target, (t, t))


def cmd_ncroot(top):
    """Folder that holds red4ext/plugins/<name>/NightCoop.dll, plus that path."""
    best = None
    for dp, _, fns in os.walk(top):
        for fn in fns:
            if fn.lower() != 'nightcoop.dll':
                continue
            parts = os.path.relpath(os.path.join(dp, fn), top).split(os.sep)
            low = [p.lower() for p in parts]
            if len(low) >= 4 and low[-3] == 'plugins' and low[-4] == 'red4ext':
                cand = (len(parts), os.path.normpath(os.path.join(top, *parts[:-4])), '/'.join(parts[-4:]))
                best = min(best, cand) if best else cand
    if not best:
        sys.exit(1)
    out(best[1], best[2])


def ci_resolve(top, rel):
    cur = top
    for comp in [c for c in rel.replace('\\', '/').split('/') if c]:
        try:
            names = os.listdir(cur)
        except OSError:
            return None
        if comp not in names:
            alt = sorted(n for n in names if n.lower() == comp.lower())
            if not alt:
                return None
            comp = alt[0]
        cur = os.path.join(cur, comp)
    return cur


def cmd_findci(top, rel):
    p = ci_resolve(top, rel)
    if not p or not os.path.lexists(p):
        sys.exit(1)
    out(p)


def cmd_rmci(top, *rels):
    for rel in rels:
        p = ci_resolve(top, rel)
        if p and os.path.isfile(p):
            os.remove(p)


def tree_map(src_top, dst_top):
    """(source, destination-relative) pairs; existing folder and file names win on case."""
    cache, res = {}, []

    def names(d):
        if d not in cache:
            try:
                cache[d] = os.listdir(d)
            except OSError:
                cache[d] = []
        return cache[d]

    for dp, dns, fns in os.walk(src_top):
        dns.sort()
        for fn in sorted(fns):
            src = os.path.join(dp, fn)
            cur, mapped = dst_top, []
            for comp in os.path.relpath(src, src_top).split(os.sep):
                ns = names(cur)
                if comp not in ns:
                    alt = sorted(n for n in ns if n.lower() == comp.lower())
                    comp = alt[0] if alt else comp
                mapped.append(comp)
                cur = os.path.join(cur, comp)
            rel = '/'.join(mapped)
            if '\t' in rel or '\n' in rel:
                die('unsupported character in file name: %r' % rel)
            res.append((src, rel))
    return res


def cmd_merge(src_top, dst_top):
    for src, rel in tree_map(src_top, dst_top):
        dst = os.path.join(dst_top, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)


def read_manifest(path):
    ents = []
    if path and os.path.isfile(path):
        with open(path, encoding='utf-8', errors='surrogateescape') as fh:
            for line in fh:
                line = line.rstrip('\n')
                if line and not line.startswith('#'):
                    st, _, rel = line.partition('\t')
                    ents.append((st, rel))
    return ents


# What NightCoop's own update guide says to keep when replacing its plugin folder.
PLUGIN_KEEP_FILES = ('servers.txt', 'hub.txt')
PLUGIN_KEEP_DIRS = ('logs',)


def tree_stale(mapping, game, prev, protect, refresh=''):
    """Files to remove: those the previous install put in place that the new archive no
    longer has, and everything else in the plugin folder (refresh) apart from the user's
    servers.txt, hub.txt and logs, so that no file of an older build stays behind.
    A protected path ending in "/" protects everything below it."""
    current = {rel.lower() for _, rel in mapping} | {p.lower() for p in protect if not p.endswith('/')}
    folders = tuple(p.lower() for p in protect if p.endswith('/'))
    stale = []

    def add(p):
        r = os.path.relpath(p, game).replace(os.sep, '/')
        if (os.path.isfile(p) or os.path.islink(p)) and r.lower() not in current \
                and not r.lower().startswith(folders) and r not in stale:
            stale.append(r)

    for st, rel in read_manifest(prev):
        if st in ('added', 'replaced', 'same'):
            p = ci_resolve(game, rel)
            if p:
                add(p)
    top = ci_resolve(game, refresh) if refresh else None
    if top and os.path.isdir(top) and not os.path.islink(top):
        for dp, dns, fns in os.walk(top):
            dns[:] = sorted(d for d in dns if d.lower() not in PLUGIN_KEEP_DIRS)
            for fn in sorted(fns):
                if fn.lower() not in PLUGIN_KEEP_FILES:
                    add(os.path.join(dp, fn))
    return stale


def plan(stage, game, prev, protect, refresh='', force=False):
    """Entries: added, replaced, same (already identical: left alone unless force) and
    removed (stale), plus the folders to create."""
    mapping = tree_map(stage, game)
    stale = tree_stale(mapping, game, prev, protect, refresh)
    mk, ents = [], []
    for src, rel in mapping:
        parts = rel.split('/')
        for i in range(1, len(parts)):
            d = '/'.join(parts[:i])
            full = os.path.join(game, d)
            if not os.path.isdir(full):
                if os.path.lexists(full):
                    die('a file is in the way of the folder ' + d)
                if d not in mk:
                    mk.append(d)
        dst = os.path.join(game, rel)
        if os.path.isdir(dst) and not os.path.islink(dst):
            die('a folder is in the way of ' + rel)
        if not os.path.lexists(dst):
            st = 'added'
        elif not force and os.path.isfile(dst) and not os.path.islink(dst) and filecmp.cmp(src, dst, shallow=False):
            st = 'same'
        else:
            st = 'replaced'
        ents.append((st, rel))
    ents += [('removed', rel) for rel in stale]
    return mapping, mk, ents


STATES = ('added', 'replaced', 'removed', 'same')


def cmd_tree_plan(stage, game, prev, refresh, force, *protect):
    _, _, ents = plan(stage, game, prev, protect, refresh, force == '1')
    out(*[sum(1 for e in ents if e[0] == s) for s in STATES])
    for st, rel in ents:
        if st == 'removed':
            out('stale', rel)


def cmd_tree_apply(stage, game, bgame, manifest, prev, refresh, force, *protect):
    mapping, mk, ents = plan(stage, game, prev, protect, refresh, force == '1')
    for st, rel in ents:                      # 1. back up everything that will change
        if st in ('replaced', 'removed'):
            b = os.path.join(bgame, rel)
            os.makedirs(os.path.dirname(b), exist_ok=True)
            shutil.copy2(os.path.join(game, rel), b, follow_symlinks=False)
    with open(manifest, 'w', encoding='utf-8', errors='surrogateescape') as fh:   # 2. record it
        # v2 adds "same": a file that already matched, left alone and not backed up
        fh.write('# nightcoop-install manifest v2; paths are relative to the game folder\n')
        fh.writelines('mkdir\t%s\n' % d for d in mk)
        fh.writelines('%s\t%s\n' % e for e in ents)
    same = {rel for st, rel in ents if st == 'same'}
    for src, rel in mapping:                  # 3. change it
        if rel in same:
            continue
        dst = os.path.join(game, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst + '.nightcoop-tmp')
        os.replace(dst + '.nightcoop-tmp', dst)
    for st, rel in ents:
        if st == 'removed':
            os.remove(os.path.join(game, rel))
            d = os.path.dirname(rel)
            while d:   # folders the removal left empty go too; restore makes them again
                try:
                    os.rmdir(os.path.join(game, d))
                except OSError:
                    break
                d = os.path.dirname(d)
    out(*[sum(1 for e in ents if e[0] == s) for s in STATES])


def cmd_tree_restore(manifest, bgame, game):
    ents, missing = read_manifest(manifest), 0
    for st, rel in reversed(ents):
        dst = os.path.join(game, rel)
        if st == 'added':
            if os.path.islink(dst) or os.path.isfile(dst):
                os.remove(dst)
        elif st in ('replaced', 'removed'):
            b = os.path.join(bgame, rel)
            if not os.path.lexists(b):
                missing += 1
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.islink(dst) or os.path.isfile(dst):
                os.remove(dst)
            shutil.copy2(b, dst, follow_symlinks=False)
    left = []
    for st, rel in reversed(ents):
        if st == 'mkdir':
            try:
                os.rmdir(os.path.join(game, rel))
            except OSError:
                if os.path.isdir(os.path.join(game, rel)):
                    left.append(rel)
    # report only the top-most folders that had to stay
    left = [d for d in left if not any(d != o and d.startswith(o + '/') for o in left)]
    out(missing, ' '.join(sorted(left)))


# Folders that hold one folder per mod; the deepest that fits wins, so a Cyber Engine Tweaks
# mod (bin/x64/plugins/cyber_engine_tweaks/mods/<mod>) is not taken for part of CET itself.
MOD_CONTAINERS = ('bin/x64/plugins/cyber_engine_tweaks/mods', 'bin/x64/plugins/cyber_engine_tweaks',
                  'bin/x64/plugins', 'red4ext/plugins', 'r6/scripts', 'r6/tweaks', 'mods')
GAME_TOPS = ('archive', 'bin', 'engine', 'mods', 'r6', 'red4ext')


def cmd_roots(top):
    """What a mod archive owns in the game folder: its own folder in a folder of mods (see
    MOD_CONTAINERS), and each file it puts anywhere else."""
    roots = []
    for _, rel in tree_map(top, top):
        low, r = rel.lower(), rel
        for c in MOD_CONTAINERS:
            if low.startswith(c + '/'):
                rest = rel[len(c) + 1:].split('/')
                if len(rest) > 1:
                    r = rel[:len(c) + 1] + rest[0] + '/'
                break
        if r not in roots:
            roots.append(r)
    for r in roots:
        out(r)


def cmd_modroot(top):
    """The folder in an unpacked mod archive that holds the game folders (r6, archive, bin,
    red4ext, engine, mods): the archive root, or a folder at most two levels below it."""
    level = [top]
    for _ in range(3):
        for d in level:
            if any(n.lower() in GAME_TOPS and os.path.isdir(os.path.join(d, n)) for n in os.listdir(d)):
                out(d)
                return
        level = [os.path.join(d, n) for d in level for n in sorted(os.listdir(d))
                 if os.path.isdir(os.path.join(d, n)) and n.lower() not in ('fomod', '__macosx')]
    die('no game folders (r6, archive, bin, red4ext, engine, mods) in the archive')


# How Nexus Mods names a download: <file name>-<mod id>-<version>-<upload time>.<ext> until 2026
# (the version's dots as dashes), <file name> <mod id> <version> <YYYY-MM-DDTHH-MMZ> <file key>.<ext>
# since. A browser adds " (1)" to a second copy.
NEXUS_NAMES = (
    (r'^(?P<name>.+)[ _]%s[ _](?P<ver>.+?)[ _](?P<iso>\d{4}-\d\d-\d\dT\d\d-\d\dZ)[ _][A-Za-z0-9]+(?: \(\d+\))?\.(?:zip|7z|rar)$', True),
    (r'^(?P<name>.+)-%s-(?P<ver>[vV]?[0-9][0-9a-zA-Z-]*?)(?:-(?P<ts>[0-9]{9,11}))?(?: \(\d+\))?\.(?:zip|7z|rar)$', False),
)


def nexus_name(fn, mod_id):
    """(file name, version, upload time) of a Nexus download of the mod, or None."""
    for pat, iso in NEXUS_NAMES:
        m = re.match(pat % re.escape(mod_id), fn, re.I)
        if m:
            ver = m.group('ver') if iso else m.group('ver').replace('-', '.')
            if ver[:1] in 'vV' and ver[1:2].isdigit():
                ver = ver[1:]
            t = calendar.timegm(time.strptime(m.group('iso'), '%Y-%m-%dT%H-%MZ')) if iso else int(m.group('ts') or 0)
            return m.group('name'), ver, t
    return None


def cmd_nexus_find(mod_id, prefer, avoid, minver, *dirs):
    """The downloads of a Nexus mod in the given folders (see NEXUS_NAMES), best first, one per
    line: path, version, and "preferred" or "other". A file whose name has <prefer> in it (e.g.
    "light") comes first, then the newest; "+word" means only such files count (a mod with several
    files that go together, each its own component). A file with one of the comma-separated
    <avoid> words in its name, or older than <minver>, is never listed: when there is nothing else,
    the newest such is named, as "avoided" or "old"; "~word" is never named (another component
    takes it). In the words "_" stands for a space. Each upload is listed once. "-" means no word
    or version."""
    need = prefer.startswith('+')
    prefer = '' if prefer in ('-', '+') else prefer.lstrip('+').lower().replace('_', ' ')
    avoid = [] if avoid == '-' else [w.replace('_', ' ') for w in avoid.lower().split(',') if w]
    quiet = [w[1:] for w in avoid if w.startswith('~')]
    avoid = [w for w in avoid if not w.startswith('~')]
    found, shunned, old = [], [], []
    for d in dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            p = os.path.join(d, n)
            got = nexus_name(n, mod_id)
            if not got or not os.path.isfile(p):
                continue
            name, ver, t = got
            low = name.lower().replace('_', ' ')
            if (need and prefer not in low) or any(w in low for w in quiet):
                continue
            key = (t, os.path.getmtime(p), p, ver, low)
            if any(w in low for w in avoid):
                shunned.append(key)
            elif minver != '-' and vcmp(ver, minver) < 0:
                old.append(key)
            else:
                found.append((1 if prefer and prefer in low else 0,) + key)
    seen = set()
    for fav, t, _, p, ver, low in sorted(found, reverse=True):
        if (t, ver, low) not in seen:
            seen.add((t, ver, low))
            out(p, ver, 'preferred' if fav or not prefer else 'other')
    if not found:
        for kind, keys in (('avoided', shunned), ('old', old)):
            if keys:
                _, _, p, ver, _ = max(keys)
                out(p, ver, kind)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for block in iter(lambda: fh.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def cmd_keep_state(files, game, recorded, *patterns):
    """Files a mod writes to while the game runs (patterns, matched without case against paths
    relative to the game folder). recorded: a file of "path<TAB>SHA-256" lines, the copy of each
    such file this script last installed. Where the game folder has the file and the mod ships the
    same copy as then (or there is no record of it), the game folder's copy replaces the one in the
    unpacked mod (files), so the player's copy stays; otherwise the new copy is installed (and the
    player's is backed up as replaced). Prints each such file with the SHA-256 the mod ships."""
    pats = [x.lower() for x in patterns]
    last = {}
    try:
        with open(recorded, encoding='utf-8', errors='surrogateescape') as fh:
            for line in fh:
                rel, _, sha = line.rstrip('\n').partition('\t')
                if rel:
                    last[rel.lower()] = sha
    except OSError:
        pass
    for src, rel in sorted(tree_map(files, files), key=lambda e: e[1].lower()):
        if not any(fnmatch.fnmatchcase(rel.lower(), x) for x in pats):
            continue
        sha = sha256_of(src)
        have = ci_resolve(game, rel)
        if have and os.path.isfile(have) and not os.path.islink(have) and last.get(rel.lower(), sha) == sha:
            shutil.copy2(have, src)
        out(rel, sha)


CMDS = {
    'roots': cmd_roots, 'modroot': cmd_modroot, 'nexus-find': cmd_nexus_find, 'keep-state': cmd_keep_state,
    'pever': cmd_pever, 'gamever': cmd_gamever, 'r4ok': cmd_r4ok, 'pestr': cmd_pestr, 'vge': cmd_vge, 'builtin': cmd_builtin, 'pecrt': cmd_pecrt,
    'libs': cmd_libs, 'proton': cmd_proton, 'slr': cmd_slr,
    'ct-get': cmd_ct_get, 'ct-list': cmd_ct_list, 'ct-pick': cmd_ct_pick, 'ct-set': cmd_ct_set,
    'lo-status': cmd_lo_status, 'lo-set': cmd_lo_set, 'lo-merge': cmd_lo_merge, 'lo-uses': cmd_lo_uses,
    'pick': cmd_pick, 'reg-get': cmd_reg_get, 'reg-set': cmd_reg_set, 'reg-del': cmd_reg_del, 'wsrv': cmd_wsrv,
    'unzip': cmd_unzip, 'ncroot': cmd_ncroot, 'findci': cmd_findci, 'rmci': cmd_rmci, 'merge': cmd_merge,
    'tree-plan': cmd_tree_plan, 'tree-apply': cmd_tree_apply, 'tree-restore': cmd_tree_restore,
}
if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
    die('nightcoop helper: unknown command %r' % sys.argv[1:2])
CMDS[sys.argv[1]](*sys.argv[2:])
PY

py()     { python3 -I -c "$PYHELPER" "$@"; }
pever()  { py pever "$1" "${2:-file}"; }
ver_ge() { py vge "$1" "$2"; }
findci() { py findci "$@"; }

# Hidden entry point for the test suite and for debugging: run one helper command.
if [ "${1:-}" = "__py" ]; then shift; py "$@"; exit $?; fi

# ---------------------------------------------------------------- output ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_B=$'\033[1m' C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_0=$'\033[0m'
else
    C_B="" C_G="" C_Y="" C_R="" C_0=""
fi
bold() { printf '%s== %s%s\n' "$C_B" "$*" "$C_0"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s[ok]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s[!!]%s %s\n' "$C_Y" "$C_0" "$*"; }
fail() { printf '  %s[XX]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
row()  { printf '  %-22s %s\n' "$1:" "$2"; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    if [ ! -t 0 ]; then info "no terminal to ask on; rerun with --yes to proceed"; return 1; fi
    local a
    read -r -p "  $1 [y/N] " a
    [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]]
}

usage() {   # the header comment, with the name this was started as (nightcoop-install when packaged)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" | sed "s/nightcoop-install\.sh/$(basename "$0")/g"
}

# ---------------------------------------------------------- argument parse ----
need_arg() { [ "$2" -ge 2 ] || fail "$1 needs a value"; }
if [ $# -gt 0 ]; then
    case "$1" in
        install|update) MODE=install; shift ;;
        check|restore|uninstall) MODE="$1"; shift ;;
        -h|--help) usage; exit 0 ;;
        --version) echo "nightcoop-install $SCRIPT_VERSION"; exit 0 ;;
    esac
fi
if [ "$MODE" = restore ] && [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then RESTORE_DIR="$1"; shift; fi
while [ $# -gt 0 ]; do
    case "$1" in
        --nightcoop-zip)  need_arg "$1" $#; NIGHTCOOP_ZIP="$(readlink -m "$2")"; shift 2 ;;
        --red4ext-zip)    need_arg "$1" $#; RED4EXT_ZIP="$(readlink -m "$2")"; shift 2 ;;
        --vcredist)       need_arg "$1" $#; VCREDIST="$(readlink -m "$2")"; shift 2 ;;
        --steam-root)     need_arg "$1" $#; OPT_STEAM_ROOT="$(readlink -m "$2")"; shift 2 ;;
        --close-steam)    CLOSE_STEAM=1; shift ;;
        --proton)         need_arg "$1" $#; PROTON_WANT="$2"; shift 2 ;;
        --no-launcher-skip) GAME_ARGS=""; shift ;;
        --game-performance) GP_OPT=on; shift ;;
        --no-game-performance) GP_OPT=off; shift ;;
        --mangohud)       MH_OPT=on; shift ;;
        --no-mangohud)    MH_OPT=off; shift ;;
        --no-save-backup) SAVE_BACKUP=0; shift ;;
        --backup-saves)   SAVE_BACKUP=1; shift ;;
        --with-flight)    SET_WANT+=(+flight); shift ;;
        --without-flight) SET_WANT+=(-flight); shift ;;
        --with-mods)      SET_WANT+=(+mods); shift ;;
        --without-mods)   SET_WANT+=(-mods); shift ;;
        --with-equipment-ex) SET_WANT+=(+eqex); shift ;;
        --without-equipment-ex) SET_WANT+=(-eqex); shift ;;
        --mods-from)      need_arg "$1" $#; NEXUS_DIRS+=("$(readlink -m "$2")"); shift 2 ;;
        --force)          FORCE=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) fail "unknown option: $1 (see --help)" ;;
    esac
done

# --------------------------------------------------------------- system ----
OS_ID="" OS_LIKE="" OS_NAME="Linux" OS_FAMILY="other" DEVICE=""
detect_os() {
    local f="${NIGHTCOOP_OS_RELEASE:-/etc/os-release}"
    osr() { sed -n "s/^$1=//p" "$f" 2>/dev/null | head -n1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }
    if [ -r "$f" ]; then
        OS_ID="$(osr ID)"; OS_LIKE="$(osr ID_LIKE)"
        OS_NAME="$(osr PRETTY_NAME)"; OS_NAME="${OS_NAME:-${OS_ID:-Linux}}"
    fi
    case "$OS_ID" in
        steamos) OS_FAMILY=steamos ;;
        cachyos) OS_FAMILY=cachyos ;;
        arch)    OS_FAMILY=arch ;;
        *) case " $OS_LIKE " in *" arch "*) OS_FAMILY=archlike ;; esac ;;
    esac
    case "$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || true):$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)" in
        Valve:Jupiter) DEVICE="Steam Deck LCD" ;;
        Valve:Galileo) DEVICE="Steam Deck OLED" ;;
    esac
}
is_arch_family() { case "$OS_FAMILY" in cachyos|arch|archlike) return 0 ;; esac; return 1; }

need_tools() {
    local t missing=() pkgs=()
    for t in python3 curl sha256sum timeout find pgrep; do
        command -v "$t" >/dev/null 2>&1 && continue
        missing+=("$t")
        case "$t" in python3) pkgs+=(python) ;; sha256sum|timeout) pkgs+=(coreutils) ;;
                     find) pkgs+=(findutils) ;; pgrep) pkgs+=(procps-ng) ;; *) pkgs+=("$t") ;; esac
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    if is_arch_family; then
        fail "missing tools: ${missing[*]}. Install them with: sudo pacman -S --needed ${pkgs[*]}"
    elif [ "$OS_FAMILY" = steamos ]; then
        fail "missing tools: ${missing[*]}. SteamOS ships these; a missing one points to a damaged system image (Settings > System > Software updates, or a SteamOS repair)."
    else
        fail "missing tools: ${missing[*]}. Install them with your package manager."
    fi
}

game_running()  { pgrep -u "$(id -u)" -x 'Cyberpunk2077.e' >/dev/null 2>&1 || pgrep -u "$(id -u)" -x 'REDprelauncher.' >/dev/null 2>&1; }
steam_running() { pgrep -u "$(id -u)" -x steam >/dev/null 2>&1 || pgrep -u "$(id -u)" -x steamwebhelper >/dev/null 2>&1; }
in_game_mode()  { [ "${XDG_CURRENT_DESKTOP:-}" = gamescope ] || [ "${XDG_SESSION_DESKTOP:-}" = gamescope ]; }
fs_type()       { findmnt -n -o FSTYPE --target "$1" 2>/dev/null || stat -f -c %T "$1" 2>/dev/null || echo unknown; }

sha_check() { [ "$(sha256sum "$1" | cut -d' ' -f1)" = "${2,,}" ]; }

download() {    # download <url> <dest> [quiet]
    local -a progress=(-sS)
    [ -z "${3:-}" ] && info "downloading $(basename "${1%%\?*}")" && [ -t 1 ] && progress=(--progress-bar)
    curl -fL "${progress[@]}" --proto '=https,file' --proto-redir '=https' --retry 3 \
         --connect-timeout 20 -o "$2" "$1"
}

# ----------------------------------------------------- locate Steam & game ----
STEAM_ROOT="" STEAM_KIND="" GAME_LIB="" GAME_DIR="" GAME_VER="" GAME_VER_ALT="" GAME_FILEVER=""
COMPAT="" PFX="" SYS32="" USERREG="" SAVES="" PROTON_DIR="" PROTON_SRC="" SLR_ENTRY=""
LIBS=()

steam_candidates() {
    local c
    if [ -n "$OPT_STEAM_ROOT" ]; then echo "$OPT_STEAM_ROOT"; return 0; fi
    for c in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" "$HOME/.steam/debian-installation" \
             "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
        if [ -d "$c/steamapps" ]; then readlink -f "$c"; fi
    done | awk '!seen[$0]++'
}
steam_kind() { case "$1" in */.var/app/com.valvesoftware.Steam/*) echo flatpak ;; *) echo native ;; esac; }

locate_game() {
    bold "Steam and Cyberpunk 2077"
    local root kind lib inst checked=()
    local -a roots
    if [ -n "$OPT_STEAM_ROOT" ] && [ ! -d "$OPT_STEAM_ROOT/steamapps" ]; then fail "--steam-root $OPT_STEAM_ROOT has no steamapps folder"; fi
    mapfile -t roots < <(steam_candidates)
    [ ${#roots[@]} -gt 0 ] || fail "no Steam installation found in ~/.local/share/Steam, ~/.steam or the Flatpak location; pass --steam-root DIR if it is elsewhere"
    for root in "${roots[@]}"; do
        kind="$(steam_kind "$root")"; LIBS=()
        while IFS=$'\x1f' read -r lib inst; do
            LIBS+=("$lib"); checked+=("$lib")
            if [ -z "$GAME_DIR" ] && [ -f "$lib/steamapps/common/${inst:-Cyberpunk 2077}/$GAME_EXE_REL" ]; then
                GAME_LIB="$lib"; GAME_DIR="$lib/steamapps/common/${inst:-Cyberpunk 2077}"
            fi
        done < <(py libs "$root" "$kind" "$APPID")
        if [ -n "$GAME_DIR" ]; then STEAM_ROOT="$root"; STEAM_KIND="$kind"; break; fi
    done
    [ -n "$GAME_DIR" ] || fail "Cyberpunk 2077 is not installed in any Steam library (checked: ${checked[*]:-none}). Install it, or mount the drive or SD card that holds it."
    ok "Steam ($STEAM_KIND client): $STEAM_ROOT"
    [ "$STEAM_KIND" = flatpak ] && info "Flatpak Steam: the files are reachable from outside the sandbox, so the install works the same way"
    ok "game folder: $GAME_DIR"
    IFS=$'\x1f' read -r GAME_VER GAME_VER_ALT GAME_FILEVER < <(py gamever "$GAME_DIR/$GAME_EXE_REL") || true
    GAME_VER="${GAME_VER:-$GAME_VER_ALT}"
    if [ -n "$GAME_VER" ]; then ok "game version: $GAME_VER${GAME_FILEVER:+ (Cyberpunk2077.exe $GAME_FILEVER)}"
    else warn "could not read the game version from Cyberpunk2077.exe"; fi
}

no_prefix_help() {
    warn "no Proton prefix yet for Cyberpunk 2077"
    if [ "$OS_FAMILY" = steamos ]; then
        cat <<'EOF'

  The game has not been started on this device yet. Launch Cyberpunk 2077 once
  from Steam (Game Mode is fine), wait for the main menu, quit, then run this again.
EOF
    else
        local tool="Proton Experimental"
        [ "$OS_FAMILY" = cachyos ] && tool="proton-cachyos (sudo pacman -S proton-cachyos-slr) or Proton Experimental"
        cat <<EOF

  The game has never been started with Proton here. Do this first:
    1. In Steam: right-click Cyberpunk 2077 > Properties > Compatibility, tick
       "Force the use of a specific Steam Play compatibility tool" and pick
       $tool.
    2. Launch the game once, wait for the main menu, then quit.
    3. Run this script again.
EOF
    fi
}

locate_prefix() {
    local lib c fs
    for lib in "$GAME_LIB" "${LIBS[@]}"; do
        c="$lib/steamapps/compatdata/$APPID"
        if [ -d "$c/pfx/drive_c/windows/system32" ]; then COMPAT="$c"; break; fi
    done
    [ -n "$COMPAT" ] || return 1
    PFX="$COMPAT/pfx"; SYS32="$PFX/drive_c/windows/system32"; USERREG="$PFX/user.reg"
    SAVES="$PFX/drive_c/users/steamuser/Saved Games/CD Projekt Red/Cyberpunk 2077"
    fs="$(fs_type "$COMPAT")"
    ok "Proton prefix: $COMPAT ($fs)"
    case "$fs" in
        ntfs|ntfs3|fuseblk|exfat|vfat|msdos)
            warn "the prefix is on $fs. Proton prefixes on Windows file systems break in odd ways; move the game to an ext4 or btrfs library (Steam > Settings > Storage)." ;;
    esac
    return 0
}

locate_proton() {
    IFS=$'\x1f' read -r PROTON_DIR PROTON_SRC < <(py proton "$STEAM_ROOT" "$STEAM_KIND" "$COMPAT" "$APPID" "${LIBS[@]}") || true
    if [ -z "$PROTON_DIR" ]; then
        warn "could not find the Proton build this game uses"
        return 0
    fi
    ok "Proton: $(proton_label) (from $PROTON_SRC)"
    SLR_ENTRY="$(py slr "$PROTON_DIR" "${LIBS[@]}" || true)"
}
proton_label() {
    local v=""
    [ -f "$PROTON_DIR/version" ] && v="$(head -n1 "$PROTON_DIR/version" | cut -s -d' ' -f2-)"
    echo "$(basename "$PROTON_DIR")${v:+ ($v)}"
}

# ----------------------------------------------------------- state readers ----
runtime_version() {
    local f
    f="$(findci "$SYS32" msvcp140.dll 2>/dev/null)" || { echo ""; return 0; }
    pever "$f" file
}
red4ext_core_version() {   # red4ext_core_version <dir> : version if RED4ext.dll and its loader are both there
    local f
    if f="$(findci "$1" red4ext/RED4ext.dll 2>/dev/null)" && findci "$1" bin/x64/winmm.dll >/dev/null 2>&1; then
        pever "$f" product
    else
        echo ""
    fi
}
runtime_kind() {   # prints: microsoft | builtin | missing
    local f
    f="$(findci "$SYS32" msvcp140.dll 2>/dev/null)" || { echo missing; return 0; }
    if py builtin "$f"; then echo builtin; else echo microsoft; fi
}
dll_overrides() {   # DLLs that must load native-first: RED4ext's loader, plus Cyber Engine Tweaks' if present or about to be
    if findci "$GAME_DIR" bin/x64/version.dll >/dev/null 2>&1 \
            || { [ -n "${TMP:-}" ] && findci "$TMP/stage" bin/x64/version.dll >/dev/null 2>&1; }; then echo winmm,version
    else echo winmm; fi
}

# Launch wrappers. CachyOS's game-performance runs the game in the performance power profile;
# it goes into the launch options when it can run, and out when it cannot, because Steam then
# fails to start the game. MangoHud's overlay goes in only when asked (--mangohud), as
# MANGOHUD=1: under Proton the game draws with Vulkan, for which that variable is what turns
# MangoHud's layer on (the mangohud wrapper sets it too, with an OpenGL hook the game does not
# use), and unlike the wrapper it cannot stop the game from starting once MangoHud is gone.
have_tool() {   # have_tool <name>: where it is on PATH (on NIGHTCOOP_TOOL_PATH in the tests)
    local d
    while IFS= read -r -d : d; do
        if [ -n "$d" ] && [ -f "$d/$1" ] && [ -x "$d/$1" ]; then echo "$d/$1"; return 0; fi
    done <<< "${NIGHTCOOP_TOOL_PATH-$PATH}:"
    return 1
}
gp_problem() {   # why game-performance cannot start the game here (nothing when it can)
    local gp
    if [ "$STEAM_KIND" = flatpak ]; then echo "Flatpak Steam cannot run it"
    elif ! gp="$(have_tool game-performance)"; then echo "it is not installed"
    elif have_tool powerprofilesctl >/dev/null; then :
    elif ! grep -q tlpctl "$gp" 2>/dev/null; then   # TLP's tlpctl came after cachyos-settings 1.4.1
        echo "it needs powerprofilesctl (power-profiles-daemon), which is not installed"
    elif ! have_tool tlpctl >/dev/null; then
        echo "it needs powerprofilesctl (power-profiles-daemon) or tlpctl (TLP), and neither is installed"
    fi
}
mh_missing() {   # why MangoHud's overlay cannot show in the game (nothing when it can)
    local fp br=""
    if [ "$STEAM_KIND" = flatpak ]; then   # its Vulkan layer, a Flatpak extension for the runtime Steam uses
        if fp="$(have_tool flatpak)"; then
            br="$("$fp" info --show-runtime com.valvesoftware.Steam 2>/dev/null | head -n1 || true)"; br="${br##*/}"
            [ -n "$br" ] && "$fp" info "org.freedesktop.Platform.VulkanLayer.MangoHud//$br" >/dev/null 2>&1 && return 0
        fi
        echo "its Flatpak extension is not installed (flatpak install flathub org.freedesktop.Platform.VulkanLayer.MangoHud${br:+//$br})"
    elif ! have_tool mangohud >/dev/null; then
        if is_arch_family; then echo "it is not installed (sudo pacman -S mangohud)"
        else echo "it is not installed (install it with your package manager)"; fi
    fi
}
setting() { if [ -f "$DATA_DIR/settings.tsv" ]; then sed -n "s/^$1\t//p" "$DATA_DIR/settings.tsv" | tail -n1; fi; }
save_settings() {   # remember --no-game-performance (or --game-performance) for later runs
    [ -n "$GP_OPT" ] && [ "$DRY_RUN" != 1 ] || return 0
    local f="$DATA_DIR/settings.tsv"
    mkdir -p "$DATA_DIR"
    { if [ -f "$f" ]; then grep -v $'^game-performance\t' "$f" || true; fi
      if [ "$GP_OPT" = off ]; then printf 'game-performance\toff\n'; fi; } > "$f.new"
    if [ -s "$f.new" ]; then mv "$f.new" "$f"; else rm -f "$f.new" "$f"; fi
}
wrap_plan() {   # wrap_plan <launch options>: WRAP, the wrapper wishes for the lo-* helpers, and why
    local used; used=" $(py lo-uses "$1") "
    GP_USED=0 MH_USED=0 MH_WRAPPER=0
    [[ "$used" != *" game-performance "* ]] || GP_USED=1
    [[ "$used" != *" mangohud "* ]] || MH_USED=1 MH_WRAPPER=1
    [[ "$used" != *" MANGOHUD=1 "* ]] || MH_USED=1
    GP_WANT="${GP_OPT:-$(setting game-performance)}"
    GP_WHY="$(gp_problem)" MH_MISSING="$(mh_missing)"
    MH_WHY="$MH_MISSING"
    [ "$OS_FAMILY" != steamos ] || MH_WHY="SteamOS has its own performance overlay (Quick Access menu > Performance)"
    if [ "$GP_WANT" = off ] || [ -n "$GP_WHY" ]; then WRAP="-game-performance"; else WRAP="+game-performance"; fi
    # the script writes the whole line: MangoHud stays when it was there and can run, or when asked for
    local mh="$MH_OPT"; [ -n "$mh" ] || [ "$MH_USED" = 0 ] || mh=on
    case "$mh" in on) [ -n "$MH_WHY" ] || WRAP+=",+mangohud" ;; off) WRAP+=",-mangohud" ;; esac
}
wrap_notes() {   # install: what happens to game-performance and MangoHud in the launch options
    if [ "$GP_USED" = 1 ] && [ -n "$GP_WHY" ]; then
        warn "the launch options run game-performance, but $GP_WHY: the game would not start, so it is taken out"
    elif [ "$GP_WANT" = off ]; then
        local how="left out of"; [ "$GP_USED" = 0 ] || how="taken out of"
        info "game-performance: $how the launch options (--no-game-performance; --game-performance adds it again)"
    elif [ -z "$GP_WHY" ] && [ "$GP_USED" = 0 ]; then
        info "game-performance found: the game will run in the performance power profile (--no-game-performance leaves it out)"
    elif [ -n "$GP_WHY" ] && [ "$GP_OPT" = on ]; then
        info "game-performance is not added: $GP_WHY"
    fi
    case "$MH_OPT" in
        on) if [ -n "$MH_WHY" ] && [ "$MH_USED" = 1 ]; then info "MangoHud: taken out of the launch options: $MH_WHY"
            elif [ -n "$MH_WHY" ]; then info "MangoHud is not added: $MH_WHY"
            elif [ "$MH_USED" = 1 ]; then ok "MangoHud is already in the launch options"
            else info "MangoHud: MANGOHUD=1 shows its overlay in the game (--no-mangohud takes it out)"; fi ;;
        off) if [ "$MH_USED" = 1 ]; then info "MangoHud: taken out of the launch options (--no-mangohud)"
             else info "--no-mangohud: MangoHud is not in the launch options"; fi ;;
        *) if [ "$MH_USED" = 1 ] && [ -n "$MH_WHY" ]; then
               info "MangoHud: taken out of the launch options: $MH_WHY"
           elif [ "$MH_USED" = 0 ] && [ -z "$MH_WHY" ]; then
               info "MangoHud is installed: --mangohud shows its overlay in the game"
           fi ;;
    esac
}
wrap_rows() {   # check: game-performance and MangoHud
    if [ "$GP_USED" = 1 ] && [ -n "$GP_WHY" ]; then
        row "game-performance" "in the launch options, but $GP_WHY"
        warn "the game will not start this way; run '$0' with Steam closed to take it out"
    elif [ "$GP_USED" = 1 ]; then row "game-performance" "in the launch options"
    elif [ -z "$GP_WHY" ] && [ "$GP_WANT" = off ]; then row "game-performance" "installed; left out (--no-game-performance)"
    elif [ -z "$GP_WHY" ]; then row "game-performance" "installed; run '$0' to start the game with it"
    fi
    if [ "$MH_WRAPPER" = 1 ] && [ -n "$MH_MISSING" ]; then
        row "MangoHud" "in the launch options, but $MH_MISSING"
        warn "the game will not start this way; install MangoHud, or run '$0' with Steam closed to take it out"
    elif [ "$MH_USED" = 1 ]; then row "MangoHud" "in the launch options"
    elif [ -z "$MH_WHY" ]; then row "MangoHud" "installed; '$0 --mangohud' shows its overlay in the game"
    fi
    return 0
}
reg_state() {   # reg_state [dlls] : ok | missing | noreg
    local v d
    [ -f "$USERREG" ] || { echo noreg; return 0; }
    for d in $(tr ',' ' ' <<<"${1:-winmm}"); do
        if ! v="$(py reg-get "$USERREG" "$REG_KEY" "$d")" || [[ "${v,,}" != n* ]]; then echo missing; return 0; fi
    done
    echo ok
}
r4_supported() { py r4ok "$1" "$GAME_FILEVER" "$RED4EXT_COMPAT"; }   # r4_supported <RED4ext version>
r4_needed() {   # the RED4ext line this game needs, for messages
    local row best="" top=""
    for row in $RED4EXT_COMPAT; do
        if [ -z "$top" ] || ver_ge "${row%%:*}" "$top"; then top="${row%%:*}"; fi
        if ver_ge "$GAME_FILEVER" "${row#*:}" && { [ -z "$best" ] || ver_ge "${row%%:*}" "$best"; }; then best="${row%%:*}"; fi
    done
    if [ -z "$best" ]; then echo "an older release"
    elif [ "$best" = "$top" ]; then echo "$best or newer"
    else echo "$best (newer releases need a newer game patch)"; fi
}
latest_backup() {   # newest backup that has not been restored yet (new or legacy layout)
    local d
    for d in "$BACKUP_ROOT"/*/ "$HOME"/nightcoop-backup-*/; do
        d="${d%/}"
        [ -d "$d" ] && [ ! -e "$d/RESTORED" ] || continue
        # this script's backups always have a manifest (one without it was interrupted);
        # the earlier Bazzite script's have a game folder instead
        case "$d" in
            "$BACKUP_ROOT"/*) [ -f "$d/manifest.tsv" ] || continue ;;
            *) [ -d "$d/game" ] || continue ;;
        esac
        printf '%s\t%s\n' "$(basename "$d" | sed 's/^nightcoop-backup-//')" "$d"
    done | sort -r | head -n1 | cut -f2
}
wait_prefix_idle() {   # wait up to $1 s for the prefix's wineserver to exit
    local t="${1:-20}"
    while [ -n "$(py wsrv "$PFX")" ]; do
        [ "$t" -le 0 ] && return 1
        sleep 1; t=$((t - 1))
    done
    return 0
}

newest() {   # newest <dir> <depth> [name pattern] : most recently modified log below dir
    find "$1" -maxdepth "$2" -type f -iname "${3:-*.log}" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true
}

runtime_verdict() {   # runtime_verdict <version> <wanted> [kind]
    if [ "${3:-}" = builtin ]; then echo "Wine's built-in runtime (works with RED4ext; Steam's first launch normally replaces it)"
    elif [ -z "$1" ]; then echo "msvcp140.dll missing"
    elif ver_ge "$1" "$2"; then echo "$1 (ok)"
    elif ver_ge "$1" "$RUNTIME_FLOOR"; then echo "$1 (works; $2 or newer recommended)"
    else echo "$1 (too old: RED4ext fails with error 998; needs $RUNTIME_FLOOR or newer)"; fi
}

# --------------------------------------------------------- install record ----
# What the last install put in place, in $DATA_DIR/installed.tsv. The SHA-256 of
# NightCoop.dll tells whether the plugin is still that build, not one copied in since.
nc_dll() {   # the NightCoop.dll in the game folder, if any
    local plugins; plugins="$(findci "$GAME_DIR" red4ext/plugins 2>/dev/null || true)"
    [ -n "$plugins" ] || return 0
    find "$plugins" -maxdepth 2 -type f -iname nightcoop.dll 2>/dev/null | head -n1 || true
}
read_installed() {   # NC_RECORDED: the release on record; NC_INSTALLED: the same, while NightCoop.dll still matches;
                     # SETS_RECORDED, ROOTS_REC and VERS_REC: the add-on sets on record, what they own, their releases
    local f="$DATA_DIR/installed.tsv" gd sha dll
    NC_RECORDED="" NC_INSTALLED="" SETS_RECORDED="" ROOTS_REC=() VERS_REC=() STATE_REC=()
    [ -r "$f" ] || return 0
    NC_RECORDED="$(sed -n 's/^version\t//p' "$f")"
    gd="$(sed -n 's/^game_dir\t//p' "$f")"; sha="$(sed -n 's/^dll_sha256\t//p' "$f")"
    [ -z "$gd" ] || [ "$gd" = "$GAME_DIR" ] || return 0
    SETS_RECORDED="$(sed -n 's/^set\t//p' "$f" | tr '\n' ' ')"
    if grep -qx $'flight\t1' "$f" && [[ " $SETS_RECORDED " != *" flight "* ]]; then SETS_RECORDED="flight $SETS_RECORDED"; fi
    SETS_RECORDED="${SETS_RECORDED% }"
    mapfile -t ROOTS_REC < <(sed -n -e 's/^root\t//p' -e 's/^flight_root\t//p' "$f")
    mapfile -t VERS_REC < <(sed -n -e 's/^ver\t//p' -e 's/^flight_ver\t//p' "$f")
    mapfile -t STATE_REC < <(sed -n 's/^state\t//p' "$f")
    if [ -n "$sha" ]; then   # records from 2.1.0 have no hash and are taken as they are
        dll="$(nc_dll)"
        [ -n "$dll" ] && [ "$(sha256sum "$dll" | cut -d' ' -f1)" = "$sha" ] || return 0
    fi
    NC_INSTALLED="$NC_RECORDED"
}
addon_record_lines() {   # addon_record_lines [recorded]: the add-ons as this run leaves them (or as recorded), for the record
    local s
    if [ "${1:-}" = recorded ]; then
        for s in $SETS_RECORDED; do printf 'set\t%s\n' "$s"; done
        if [ "${#ROOTS_REC[@]}" -gt 0 ]; then printf 'root\t%s\n' "${ROOTS_REC[@]}"; fi
        if [ "${#VERS_REC[@]}" -gt 0 ]; then printf 'ver\t%s\n' "${VERS_REC[@]}"; fi
        if [ "${#STATE_REC[@]}" -gt 0 ]; then printf 'state\t%s\n' "${STATE_REC[@]}"; fi
        return 0
    fi
    for s in $SETS_ON; do printf 'set\t%s\n' "$s"; done
    if [ "${#ADDON_ROOTS[@]}" -gt 0 ]; then printf 'root\t%s\n' "${ADDON_ROOTS[@]}"; fi
    if [ "${#ADDON_VERS[@]}" -gt 0 ]; then printf 'ver\t%s\n' "${ADDON_VERS[@]}"; fi
    if [ "${#ADDON_STATE_NEW[@]}" -gt 0 ]; then printf 'state\t%s\n' "${ADDON_STATE_NEW[@]}"; fi
}
write_record() {   # write_record <version> <protocol> <games> <red4ext> <backup> <dll sha256> <add-on lines>
    mkdir -p "$DATA_DIR"
    { printf 'version\t%s\nprotocol\t%s\ngame\t%s\nred4ext\t%s\ninstalled\t%s\nbackup\t%s\ngame_dir\t%s\ndll_sha256\t%s\n' \
          "${1:-unknown}" "$2" "$3" "$4" "$(date -Is)" "$5" "$GAME_DIR" "$6"
      if [ -n "$7" ]; then printf '%s\n' "$7"; fi
    } > "$DATA_DIR/installed.tsv"
}
record_install() {   # record_install <version> <protocol> <games> <red4ext> <backup or "">: what is in place now
    local dll sha="" fl
    dll="$(nc_dll)"; [ -z "$dll" ] || sha="$(sha256sum "$dll" | cut -d' ' -f1)"
    fl="$(addon_record_lines)"
    write_record "$1" "$2" "$3" "$4" "$5" "$sha" "$fl"
    # the backup keeps it too, for the record to go back to when a later install is undone
    if [ -n "$5" ] && [ -f "$5/info.tsv" ]; then
        { printf 'dll_sha256\t%s\n' "$sha"; if [ -n "$fl" ]; then printf '%s\n' "$fl"; fi; } >> "$5/info.tsv"
    fi
    NC_RECORDED="${1:-unknown}" NC_INSTALLED="${1:-unknown}" SETS_RECORDED="$SETS_ON"
    ROOTS_REC=("${ADDON_ROOTS[@]}") VERS_REC=("${ADDON_VERS[@]}") STATE_REC=("${ADDON_STATE_NEW[@]}")
}
rerecord() {   # after a restore: the record describes the newest install still in place, if any
    local b; b="$(latest_backup)"
    if [ -n "$b" ] && [ -f "$b/info.tsv" ]; then
        write_record "$(sed -n 's/^nightcoop\t//p' "$b/info.tsv")" "" "" "$(sed -n 's/^red4ext\t//p' "$b/info.tsv")" "$b" \
            "$(sed -n 's/^dll_sha256\t//p' "$b/info.tsv" | tail -n1)" \
            "$(grep -E $'^(set|root|ver|state|flight|flight_root|flight_ver)\t' "$b/info.tsv" || true)"
    else
        rm -f "$DATA_DIR/installed.tsv"
    fi
    read_installed
}
latest_release() {   # LATEST_STATUS (ok, none, error, offline) and LATEST_VER: the site's build for this game patch
    LATEST_STATUS=offline LATEST_VER=""
    [ -s "$TMP/releases.json" ] || download "$NIGHTCOOP_SITE/releases.json" "$TMP/releases.json" quiet 2>/dev/null || return 0
    IFS=$'\x1f' read -r LATEST_STATUS LATEST_VER _ < <(py pick "$TMP/releases.json" "$GAME_VER,$GAME_VER_ALT" "$NIGHTCOOP_SITE") \
        || LATEST_STATUS=error
}

# ------------------------------------------------------------------ check ----
do_check() {
    bold "Current state"
    if game_too_old; then warn "game ${GAME_VER:-$GAME_FILEVER} is older than patch $MIN_GAME_PATCH, the oldest this installer supports; update it in Steam"; fi
    local f v crt who lo lo_val lo_winmm mm log plugins rv kind want dlls app def rel
    v="$(red4ext_core_version "$GAME_DIR")"
    if [ -n "$v" ]; then
        if r4_supported "$v"; then row "RED4ext" "$v (supports game ${GAME_VER:-?})"
        else row "RED4ext" "$v (DOES NOT support game ${GAME_VER:-?}; needs $(r4_needed); run install again)"; fi
    elif findci "$GAME_DIR" red4ext/RED4ext.dll >/dev/null 2>&1; then row "RED4ext" "RED4ext.dll present but bin/x64/winmm.dll (its loader) is missing"
    else row "RED4ext" "not installed"; fi
    plugins="$(findci "$GAME_DIR" red4ext/plugins 2>/dev/null || true)"
    f="$(nc_dll)"
    if [ -n "$f" ]; then
        v="$(pever "$f" product)"
        if [ -n "$NC_INSTALLED" ]; then rel=", release $NC_INSTALLED"
        elif [ -n "$NC_RECORDED" ]; then rel=", changed since this script installed $NC_RECORDED"
        else rel=""; fi
        row "NightCoop" "${v:+$v, }$(date -r "$f" +%F)$rel"
    else row "NightCoop" "not installed"; fi
    latest_release
    case "$LATEST_STATUS" in
        ok) if [ -z "$f" ]; then row "NightCoop update" "$LATEST_VER is the build for game ${GAME_VER:-?}; run '$0' to install it"
            elif [ "$NC_INSTALLED" = "$LATEST_VER" ]; then row "NightCoop update" "none; $LATEST_VER is the latest for game ${GAME_VER:-?}"
            elif [[ "$NC_INSTALLED" == local:* ]]; then row "NightCoop update" "installed from a local archive; the site's build for game ${GAME_VER:-?} is $LATEST_VER"
            elif [ -n "$NC_INSTALLED" ]; then row "NightCoop update" "$NC_INSTALLED -> $LATEST_VER available; run '$0 update'"
            else row "NightCoop update" "the site's build for game ${GAME_VER:-?} is $LATEST_VER; run '$0 update' to make sure it is the one installed"; fi ;;
        none) row "NightCoop update" "the site lists no builds" ;;
        *) row "NightCoop update" "unknown (could not reach $NIGHTCOOP_SITE)" ;;
    esac
    addon_rows
    IFS=$'\x1f' read -r app def < <(py ct-get "$STEAM_ROOT" "$APPID") || true
    if [ -n "$app" ]; then row "Proton for the game" "$app (chosen in Steam)"
    else row "Proton for the game" "not chosen; Steam uses ${def:-its default}"; fi
    if [ -z "$COMPAT" ]; then row "Proton prefix" "missing (launch the game once)"; return 0; fi
    IFS=$'\x1f' read -r crt who < <(py pecrt "$GAME_DIR/red4ext" "$GAME_DIR/bin/x64/winmm.dll") || true
    want="$RUNTIME_FLOOR"; [ -n "$crt" ] && ver_ge "$crt" "$want" && want="$crt"
    rv="$(runtime_version)"; kind="$(runtime_kind)"
    row "C++ runtime (prefix)" "$(runtime_verdict "$rv" "$want" "$kind")"
    if [ "$kind" != builtin ] && { [ -z "$rv" ] || ! ver_ge "$rv" "$RUNTIME_FLOOR"; }; then
        info "fix: run '$0' again (it installs the runtime); if that does not help:"
        protontricks_hint
    fi
    [ -n "$crt" ] && row "DLLs built with" "MSVC $crt (newest: $who)"
    dlls="$(dll_overrides)"
    case "$(reg_state "$dlls")" in
        ok) row "DLL override" "$dlls = native,builtin in the prefix registry" ;;
        noreg) row "DLL override" "prefix has no user.reg" ;;
        *) row "DLL override" "$dlls not set in the prefix registry" ;;
    esac
    IFS=$'\x1f' read -r lo lo_val lo_winmm < <(py lo-status "$STEAM_ROOT" "$APPID" "$dlls" "$GAME_ARGS") || true
    case "$lo" in ok|broken|missing)
        wrap_plan "$lo_val"
        IFS=$'\x1f' read -r lo lo_val lo_winmm < <(py lo-status "$STEAM_ROOT" "$APPID" "$dlls" "$GAME_ARGS" "$WRAP") || true ;;
    esac
    case "$lo" in
        ok) row "launch options" "$lo_val" ;;
        broken) row "launch options" "WINEDLLOVERRIDES present but placed after %command% or without it: $lo_val" ;;
        missing) row "launch options" "${lo_val:-empty}; recommended: $(py lo-merge "$lo_val" "$dlls" "$GAME_ARGS" "$WRAP" | cut -d$'\x1f' -f2)" ;;
        *) row "launch options" "Steam user config not found" ;;
    esac
    case "$lo" in ok|broken|missing) wrap_rows ;; esac
    if [ "$(reg_state winmm)" != ok ] && [ "${lo_winmm:-}" != ok ]; then
        warn "neither override is set: Proton will ignore RED4ext's loader and the mod will not start"
    fi
    mm="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
    if [ "$mm" -ge 1048576 ] 2>/dev/null; then row "vm.max_map_count" "$mm"
    else
        warn "vm.max_map_count is $mm; Cyberpunk 2077 wants 1048576 or more"
        is_arch_family && info "fix: echo 'vm.max_map_count = 1048576' | sudo tee /etc/sysctl.d/80-cyberpunk.conf && sudo sysctl --system"
    fi
    local logs; logs="$(findci "$GAME_DIR" red4ext/logs 2>/dev/null || echo /nonexistent)"
    log="$(newest "$logs" 1 'red4ext*.log')"
    if [ -n "$log" ]; then
        row "latest RED4ext log" "$(basename "$log")"
        grep -E 'is initializing|Product version|successfully initialized|did not initialize|plugin\(s\) loaded|has been loaded|\[error|\[critical' "$log" 2>/dev/null | head -n8 | sed 's/^/      /' || true
        [ -s "$log" ] || warn "the log is empty: RED4ext stopped before it could write (the error 998 symptom; run install again)"
    else
        row "latest RED4ext log" "none yet (game not started since install)"
    fi
    log="$(newest "$logs" 1 'nightcoop*.log')"; [ -n "$log" ] && row "latest NightCoop log" "$(basename "$log")"
    log=""; [ -n "$plugins" ] && log="$(newest "$plugins" 3 '*.log')"
    [ -n "$log" ] && row "crash/hang logs" "${log#"$GAME_DIR"/}"
    f="$(latest_backup)"; [ -n "$f" ] && row "latest backup" "$f"
    return 0
}

# ------------------------------------------------------- restore/uninstall ----
restore_one() {   # restore_one <backup dir>
    local b="$1" missing left had key name prev
    bold "Restoring from $b"
    if [ -f "$b/info.tsv" ]; then
        local recorded; recorded="$(sed -n 's/^game_dir\t//p' "$b/info.tsv")"
        [ -z "$recorded" ] || [ "$recorded" = "$GAME_DIR" ] || warn "this backup was made for $recorded; restoring into $GAME_DIR"
    fi
    if [ -f "$b/manifest.tsv" ]; then
        IFS=$'\x1f' read -r missing left < <(py tree-restore "$b/manifest.tsv" "$b/game" "$GAME_DIR") \
            || fail "restoring the game folder from $b failed"
        ok "game folder restored"
        [ "${missing:-0}" = 0 ] || warn "$missing backed-up file(s) were missing from the backup"
        [ -z "$left" ] || info "left in place because they now hold other files (logs, other mods): $left"
    elif [ -d "$b/game" ] && [[ "$(basename "$b")" == nightcoop-backup-* ]]; then   # backup made by the 1.x (Bazzite) script
        if [ -f "$b/game/bin/x64/winmm.dll" ]; then cp -a "$b/game/bin/x64/winmm.dll" "$GAME_DIR/bin/x64/winmm.dll"; else rm -f "$GAME_DIR/bin/x64/winmm.dll"; fi
        rm -rf "$GAME_DIR/red4ext"
        if [ -d "$b/game/red4ext" ]; then cp -a "$b/game/red4ext" "$GAME_DIR/red4ext"; fi
        ok "game folder restored (backup from the earlier script)"
    fi
    if [ -n "$COMPAT" ] && [ -d "$b/prefix-runtime" ] && [ -n "$(ls -A "$b/prefix-runtime" 2>/dev/null)" ]; then
        cp -a "$b/prefix-runtime/." "$SYS32/"
        ok "prefix C++ runtime restored ($(runtime_version))"
    fi
    if [ -n "$COMPAT" ] && [ -f "$b/registry.tsv" ] && [ -f "$USERREG" ]; then
        wait_prefix_idle 30 || fail "Wine is still running in the game's prefix; wait a moment and try again"
        while IFS=$'\t' read -r had key name prev; do
            if [ "$had" = 1 ]; then py reg-set "$USERREG" "$key" "$name" "$prev"; else py reg-del "$USERREG" "$key" "$name"; fi
        done < "$b/registry.tsv"
        ok "prefix registry override restored"
    fi
    date -Is > "$b/RESTORED"
}

do_restore() {
    game_running && fail "Cyberpunk 2077 is running; quit it first"
    local latest b; latest="$(latest_backup)"; b="${RESTORE_DIR:-$latest}"
    [ -n "$b" ] || fail "no backup to restore (looked in $BACKUP_ROOT)"
    [ -d "$b" ] || fail "no such backup folder: $b"
    [ -n "$RESTORE_DIR" ] || info "most recent backup: $b"
    confirm "Restore the game folder and prefix from this backup?" || { info "aborted"; exit 1; }
    restore_one "$b"
    # the game folder is back to the install before this one; an older backup restored
    # out of turn leaves it in no recorded state
    if [ "$b" = "$latest" ]; then rerecord; else rm -f "$DATA_DIR/installed.tsv"; fi
    info "Steam's launch options and Proton choice were not changed; adjust them under Properties if you wish."
}

do_uninstall() {
    game_running && fail "Cyberpunk 2077 is running; quit it first"
    local b n=0
    [ -n "$(latest_backup)" ] || fail "nothing to uninstall: no install backups in $BACKUP_ROOT"
    confirm "Undo every NightCoop install made by this script, newest first?" || { info "aborted"; exit 1; }
    while b="$(latest_backup)" && [ -n "$b" ]; do restore_one "$b"; n=$((n + 1)); done
    rm -f "$DATA_DIR/installed.tsv"
    echo
    ok "$n install(s) undone; backups (and any save copies) remain in $BACKUP_ROOT"
    info "Steam's launch options and Proton choice were not changed; adjust them under Properties if you wish."
}

# ---------------------------------------------------------------- install ----
NC_STATUS="" NC_VER="" NC_URL="" NC_SHA="" NC_GAMES="" NC_PROTO="" NC_R4="" NC_MATCHED="" NC_YANKED="" NC_PRESENT=""
PLAN_ADDED=0 PLAN_REPLACED=0 PLAN_REMOVED=0 PLAN_SAME=0 PLAN_STALE=() FILES_CHANGE=0 PREFIX_CHANGE=0 STEAM_CHANGE=0 SAVE_AUTO=""
SETS_ON="" SETS_DROPPED="" ADDON_ROOTS=() ADDON_VERS=() ADDON_STATE_NEW=() ADDON_PLAN=() ADDON_KEEP=() ADDON_DROP=() ADDON_GONE=() ADDON_NOPL=() ADDON_MISSING=() ADDON_HAVE=" " ADDON_USED=" " PROTECT=()
NC_ROOT="" NC_DLL_REL="" NC_PLUGIN_DIR="" R4_CHOICE="" R4_FINAL="" RT_WANT="" RT_TARGET="" RV="" RK="" NEED_RT=0
VCREDIST_VER="" REG_STATE="" LO_STATE="" LO_VALUE="" LO_WINMM="" RESTART_STEAM=0 DLLS="winmm"
WRAP="" GP_WANT="" GP_WHY="" GP_USED=0 MH_WHY="" MH_MISSING="" MH_USED=0 MH_WRAPPER=0
TOOL_NAME="" TOOL_DIR="" TOOL_REASON="" TOOL_LABEL="" TOOL_STATE="none"

step_nightcoop() {
    bold "NightCoop build"
    local local_sha=""
    if [ -n "$NIGHTCOOP_ZIP" ]; then
        [ -f "$NIGHTCOOP_ZIP" ] || fail "no such file: $NIGHTCOOP_ZIP"
        local_sha="$(sha256sum "$NIGHTCOOP_ZIP" | cut -d' ' -f1)"
        ok "local archive: $NIGHTCOOP_ZIP"
    fi
    NC_STATUS=offline
    if download "$NIGHTCOOP_SITE/releases.json" "$TMP/releases.json" quiet 2>/dev/null; then
        IFS=$'\x1f' read -r NC_STATUS NC_VER NC_URL NC_SHA NC_GAMES NC_PROTO NC_R4 NC_MATCHED NC_YANKED \
            < <(py pick "$TMP/releases.json" "$GAME_VER,$GAME_VER_ALT" "$NIGHTCOOP_SITE" "$local_sha") || NC_STATUS=error
    else
        warn "could not reach $NIGHTCOOP_SITE; working offline"
    fi
    case "$NC_STATUS" in
        match)
            ok "archive verified: NightCoop $NC_VER for game $NC_GAMES, protocol $NC_PROTO${NC_R4:+, bundles RED4ext $NC_R4} (SHA-256 matches the site)"
            [ "$NC_YANKED" = 1 ] && warn "the developers have withdrawn (yanked) this build"
            [ "$NC_MATCHED" = 1 ] || warn "this build does not list game version '${GAME_VER:-unknown}'; it may refuse to load" ;;
        ok)
            if [ -n "$NIGHTCOOP_ZIP" ]; then
                [ "$(basename "$NIGHTCOOP_ZIP")" != "$(basename "${NC_URL:-none}")" ] || \
                    fail "SHA-256 mismatch: $NIGHTCOOP_ZIP has the name of the published $NC_VER archive but different content; delete it and run again without --nightcoop-zip"
                warn "this archive is not listed on $NIGHTCOOP_SITE, so it cannot be verified (the site's build for this game version is $NC_VER)"
                NC_VER="local:$(basename "$NIGHTCOOP_ZIP")"; NC_PROTO=""
            else
                ok "build for game ${GAME_VER:-?}: NightCoop $NC_VER (for game $NC_GAMES, protocol $NC_PROTO${NC_R4:+, bundles RED4ext $NC_R4})"
                [ "$NC_MATCHED" = 1 ] || warn "NightCoop $NC_VER does not list game version '${GAME_VER:-unknown}'; it may refuse to load"
                [ -n "$NC_URL" ] || fail "the site lists no download for $NC_VER; download it from $NIGHTCOOP_SITE and pass --nightcoop-zip FILE"
                local name cache="$CACHE_DIR/nightcoop"; name="$(basename "${NC_URL%%\?*}")"
                if [ -n "$NC_SHA" ] && [ -f "$cache/$name" ] && sha_check "$cache/$name" "$NC_SHA"; then
                    NIGHTCOOP_ZIP="$cache/$name"
                    ok "$name was downloaded before; SHA-256 matches the site's release list"
                else
                    NIGHTCOOP_ZIP="$TMP/$name"
                    download "$NC_URL" "$NIGHTCOOP_ZIP" || fail "download failed: $NC_URL"
                    if [ -z "$NC_SHA" ]; then warn "the site publishes no checksum for this archive"
                    elif sha_check "$NIGHTCOOP_ZIP" "$NC_SHA"; then
                        ok "SHA-256 matches the site's release list"
                        if [ "$DRY_RUN" != 1 ] && mkdir -p "$cache"; then   # kept for the next run, in place of older builds
                            find "$cache" -mindepth 1 -maxdepth 1 -type f ! -name "$name" -delete 2>/dev/null || true
                            cp "$NIGHTCOOP_ZIP" "$cache/$name.part" && mv -f "$cache/$name.part" "$cache/$name" || true
                        fi
                    else fail "SHA-256 mismatch for the downloaded $NIGHTCOOP_ZIP"; fi
                fi
            fi ;;
        none|error|offline)
            [ "$NC_STATUS" = none ] && warn "the site lists no builds"
            [ "$NC_STATUS" = error ] && warn "the site's release list could not be read"
            [ -n "$NIGHTCOOP_ZIP" ] || fail "cannot work out what to download; get the archive from $NIGHTCOOP_SITE and pass --nightcoop-zip FILE"
            warn "installing $NIGHTCOOP_ZIP without verification"
            NC_VER="local:$(basename "$NIGHTCOOP_ZIP")" ;;
    esac
    return 0
}

step_stage() {
    mkdir -p "$TMP/nc" "$TMP/stage"
    py unzip "$NIGHTCOOP_ZIP" "$TMP/nc" || fail "could not unpack $NIGHTCOOP_ZIP"
    IFS=$'\x1f' read -r NC_ROOT NC_DLL_REL < <(py ncroot "$TMP/nc") \
        || fail "the archive has no red4ext/plugins/<name>/NightCoop.dll; is it a NightCoop release?"
    find "$NC_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name __MACOSX -exec cp -a {} "$TMP/stage/" \;
    local skipped; skipped="$(find "$NC_ROOT" -mindepth 1 -maxdepth 1 -type f -printf '%f ' || true)"
    NC_PLUGIN_DIR="$(dirname "$NC_DLL_REL")"
    ok "archive holds $(find "$TMP/stage" -type f | wc -l) files for the game folder, plugin $NC_DLL_REL"
    [ -z "$skipped" ] || info "top-level documents left out of the game folder: $skipped"
}

step_red4ext() {
    bold "RED4ext"
    local inst bundled rel_ver="$RED4EXT_VER" src r4dir="$TMP/r4" c v
    inst="$(red4ext_core_version "$GAME_DIR")"
    bundled="$(red4ext_core_version "$TMP/stage")"
    if [ -n "$RED4EXT_ZIP" ]; then   # a local archive may hold a different release than the pinned one
        [ -f "$RED4EXT_ZIP" ] || fail "no such file: $RED4EXT_ZIP"
        mkdir -p "$r4dir"; py unzip "$RED4EXT_ZIP" "$r4dir" || fail "could not unpack $RED4EXT_ZIP"
        rel_ver="$(red4ext_core_version "$r4dir")"
        [ -n "$rel_ver" ] || fail "$RED4EXT_ZIP is not a RED4ext release (needs red4ext/RED4ext.dll and bin/x64/winmm.dll)"
    fi
    info "installed: ${inst:-none}; bundled with NightCoop: ${bundled:-none}; ${RED4EXT_ZIP:+local }release: $rel_ver"
    [ -z "$GAME_FILEVER" ] || info "game ${GAME_VER:-?} needs RED4ext $(r4_needed)"
    # The newest candidate that supports the installed game. On a tie the bundled copy wins
    # (NightCoop pairs it with its build), then the release, then what is installed.
    R4_CHOICE=""
    for c in bundled release installed; do
        case "$c" in bundled) v="$bundled" ;; release) v="$rel_ver" ;; installed) v="$inst" ;; esac
        if [ -n "$v" ] && r4_supported "$v" && { [ -z "$R4_CHOICE" ] || ! ver_ge "$R4_FINAL" "$v"; }; then
            R4_CHOICE="$c"; R4_FINAL="$v"
        fi
    done
    if [ -z "$R4_CHOICE" ]; then   # e.g. a game patch newer than this script knows
        if [ -n "$bundled" ]; then R4_CHOICE=bundled; R4_FINAL="$bundled"; else R4_CHOICE=release; R4_FINAL="$rel_ver"; fi
        warn "no RED4ext at hand is known to support game ${GAME_VER:-?}; using $R4_FINAL"
    fi
    if [ -n "$inst" ] && ! r4_supported "$inst"; then
        warn "the installed RED4ext $inst does not support game ${GAME_VER:-?} (NightCoop would not load); it will be replaced"
    fi
    case "$R4_CHOICE" in
        bundled)
            ok "using RED4ext $bundled from the NightCoop archive" ;;
        installed)
            py rmci "$TMP/stage" "${RED4EXT_CORE[@]}"
            ok "keeping the installed RED4ext $inst, which is newer and supports this game" ;;
        release)
            if [ -n "$RED4EXT_ZIP" ]; then
                src="$RED4EXT_ZIP"
            else
                src="$TMP/red4ext-$RED4EXT_VER.zip"
                download "$RED4EXT_URL" "$src" || fail "download failed: $RED4EXT_URL"
                mkdir -p "$r4dir"; py unzip "$src" "$r4dir" || fail "could not unpack $src"
                [ -n "$(red4ext_core_version "$r4dir")" ] || fail "unexpected RED4ext archive layout"
            fi
            if sha_check "$src" "$RED4EXT_SHA"; then ok "RED4ext $rel_ver archive verified (SHA-256)"
            elif [ -n "$RED4EXT_ZIP" ] && [ "$(py vge "$rel_ver" "$RED4EXT_VER" && py vge "$RED4EXT_VER" "$rel_ver" && echo same)" != same ]; then
                warn "RED4ext $rel_ver from $RED4EXT_ZIP cannot be verified (only $RED4EXT_VER is pinned)"
            else fail "SHA-256 mismatch for $src (expected $RED4EXT_SHA)"; fi
            py rmci "$TMP/stage" "${RED4EXT_CORE[@]}"
            py merge "$r4dir" "$TMP/stage"
            if [ -n "$bundled" ]; then ok "RED4ext $rel_ver will replace the bundled $bundled"; else ok "RED4ext $rel_ver will be installed"; fi ;;
    esac
}

# ------------------------------------------------------------------ add-ons ----
addon_lines() {   # addon_lines [all]: the add-on table's lines for the installed game patch (or all of them)
    local comp patch rest
    while read -r comp patch rest; do
        [ -n "$comp" ] || continue
        if [ "${1:-}" = all ] || [ "$patch" = "$GAME_VER" ] || [ "$patch" = "$GAME_VER_ALT" ]; then echo "$comp $patch $rest"; fi
    done <<<"$ADDON_SETS"
}
addon_parts() {   # each component once: name sets kind rule version-file
    local comp patch sets kind rule probe rest seen=" "
    while read -r comp patch sets kind rule probe rest; do
        if [[ "$seen" != *" $comp "* ]]; then seen+="$comp "; echo "$comp $sets $kind $rule $probe"; fi
    done < <(addon_lines all)
}
name_of() { echo "${1//_/ }"; }   # name_of <component>: its name for people
set_label() { case "$1" in flight) echo "Let There Be Flight" ;; eqex) echo "Equipment-EX" ;; *) echo "the mod set" ;; esac; }
listing() { local IFS=,; local s="$*"; echo "${s//,/, }"; }   # listing <items...>: "a, b, c"
in_sets_on() {   # in_sets_on <sets>: one of its comma-separated sets is on ("mods+eqex": both of them)
    local s p
    for s in ${1//,/ }; do
        for p in ${s//+/ }; do [[ " $SETS_ON " == *" $p "* ]] || continue 2; done
        return 0
    done
    return 1
}
has_pl() { findci "$GAME_DIR" archive/pc/ep1 >/dev/null 2>&1; }   # Phantom Liberty is installed
needs_pl() { [[ " $(needs_of "$1") " == *" Phantom_Liberty "* ]]; }
recorded_roots() {   # recorded_roots <component>: what the last install put in place for it
    local e; for e in "${ROOTS_REC[@]}"; do if [ "${e%%$'\t'*}" = "$1" ]; then echo "${e#*$'\t'}"; fi; done
}
present_root() {   # present_root <component>: the first of its recorded files or folders still in the game folder
    local r d; while IFS= read -r r; do d="$(findci "$GAME_DIR" "${r%/}" 2>/dev/null || true)"; if [ -n "$d" ]; then echo "$d"; return 0; fi; done < <(recorded_roots "$1")
}
gone_parts() {   # components an earlier version installed that the table no longer has (their files go as stale)
    local e c known=" " seen=" "
    while read -r c _; do known+="$c "; done < <(addon_parts)
    for e in "${ROOTS_REC[@]}"; do
        c="${e%%$'\t'*}"
        if [[ "$known$seen" != *" $c "* ]]; then seen+="$c "; echo "$c"; fi
    done
}
needs_of() { local e; for e in $ADDON_NEEDS; do if [ "${e%%:*}" = "$1" ]; then tr ',' ' ' <<<"${e#*:}"; fi; done; }
restage() {   # restage <root>...: these files and folders as the game folder has them, so the plan finds
    # them unchanged and the new manifest still counts them as this script's (a later drop removes them)
    local r d rel
    for r in "$@"; do
        d="$(findci "$GAME_DIR" "${r%/}" 2>/dev/null || true)"; [ -n "$d" ] || continue
        rel="${d#"$GAME_DIR"/}"; mkdir -p "$TMP/stage/$(dirname "$rel")"
        cp -a "$d" "$TMP/stage/$(dirname "$rel")/"
    done
}
keep_recorded() {   # keep_recorded <component>: leave it as the last install put it
    local r e roots=()
    while IFS= read -r r; do roots+=("$r"); ADDON_ROOTS+=("$1"$'\t'"$r"); done < <(recorded_roots "$1")
    restage "${roots[@]}"
    for e in "${VERS_REC[@]}"; do if [ "${e%%$'\t'*}" = "$1" ]; then ADDON_VERS+=("$e"); fi; done
    for e in "${STATE_REC[@]}"; do if [ "${e%%$'\t'*}" = "$1" ]; then ADDON_STATE_NEW+=("$e"); fi; done
    ADDON_HAVE+="$1 "
}
state_files() {   # state_files <component> <its unpacked files>: the player keeps the files the mod writes to
    local c p e pats=()
    while read -r c p; do if [ -n "$c" ] && { [ "$c" = "*" ] || [ "$c" = "$1" ]; }; then pats+=("$p"); fi; done <<<"$ADDON_STATE"
    [ "${#pats[@]}" -gt 0 ] || return 0
    : > "$TMP/addons/$1.state"
    for e in "${STATE_REC[@]}"; do if [ "${e%%$'\t'*}" = "$1" ]; then printf '%s\n' "${e#*$'\t'}" >> "$TMP/addons/$1.state"; fi; done
    while IFS=$'\x1f' read -r p e; do
        if [ -n "$p" ]; then ADDON_STATE_NEW+=("$1"$'\t'"$p"$'\t'"$e"); fi
    done < <(py keep-state "$2" "$GAME_DIR" "$TMP/addons/$1.state" "${pats[@]}")
}
nexus_file() {   # nexus_file <component>: which file to download, of a mod with several
    case "$1" in
        A.G.I.S.) echo "the main file, PUBLICNET" ;;
        No_Intro_Videos) echo "the archive file" ;;
        Cyber_Drift) echo "the Light file" ;;
        Zenitex_Virtual_Atelier) ;;
        Zenitex_*_*) echo "the main file, not Alt. Colors or GS" ;;
        Comfy_Boots) echo "the Female V and Male V file" ;;
        Vehicle_Pack_Basic_1) echo "Car Pack 1" ;;
        Vehicle_Pack_Basic_2) echo "Car Pack 2" ;;
        Bikes_of_the_Dark_Future) echo "the mandatory main file, BDF_DRe_ArchV4" ;;
        Toyota_Supra_HKS) echo "the main file, KRNLNIK Toyota Supra MK5 HKS Widebody" ;;
        Porsche_911_GT3_RS) echo "the Main File" ;;
        Material_and_Texture_Override) echo "the Legacy file, not REDmod" ;;
        Vehicle_Customizer) echo "SVE 3dot0, among the main files" ;;
        Vehicle_Customizer_update) echo "SVE 3dot1, among the update files" ;;
        Immersive_Audio_Distance) echo "the main file for 2.5, Immersive Voice Distance (2.5)" ;;
        Toyota_GR_Yaris) echo "the main file Toyota Yaris GR All Purpose Drive Spec, not the Drift Handling Spec" ;;
        Toyota_GR_Yaris_Rocket_Bunny) echo "GR YARIS Rocket Bunny Kit, among the main files" ;;
        Nissan_Silvia_S14) echo "the main file, S14 Nomad Main files and Livery 1" ;;
        VendorsXL) echo "the main file, not the template and example files" ;;
        Equipment_EX) echo "the main file, not the Hide Hub Buttons patch" ;;
        Fifth_Element_Collection) echo "ALL IN ONE - Fifth Element Collection" ;;
        Dexter_Pants) echo "Dexter's Pants" ;;
        Dexter_Vest) echo "Dexter's Vest" ;;
        Dexter_Shoes) echo "Dexter's Shoes" ;;
        Street_Ninja_Remake) echo "the main file, STREET NINJA REMAKE - MAIN" ;;
        Street_Ninja_Shop) echo "STREET NINJA STREETWEAR SHOP, among the optional files" ;;
        Nola_Virtual_Boutique) echo "ND_female_virtual_boutique" ;;
        Preem_Hair) echo "Preem Hair (2K), not the 4K file" ;;
        Wolfcut_Messy) echo "Messy Wolfcut - CCXL" ;;
        Wolfcut_Emo) echo "Emo Wolfcut - CCXL" ;;
        Wolfcut_Hime_Short) echo "Hime Short - CCXL" ;;
        Wolfcut_Hime_Medium) echo "Hime Medium - CCXL" ;;
        Wolfcut_Hime_Long) echo "Hime Long Jelly - CCXL" ;;
        Subleader_Hair_Pack) echo "CCXL Sub Hair Pack - AllInOne" ;;
        Hyst_Hair_Collection) echo "1. AIO - ALL IN ONE - HYST HAIR COLLECTION" ;;
        Meluminary_Hair_Megapak) echo "CCXL - HAIR MEGAPAK" ;;
        Undercut_Slickback) echo "HAIR 01 - Slickback Undercut" ;;
        Undercut_Sidewave) echo "HAIR 02 - Sidewave Undercut" ;;
        Undercut_ManBun) echo "HAIR 03 - ManBun Undercut" ;;
        Undercut_Slickback_Braids) echo "HAIR 04 - Slickback Braids Undercut" ;;
        Chain_Jewelry) echo "Chain Jewelry - Main" ;;
        raem_Accessory_Store) echo "Accessories - Main Store, among the optional files" ;;
    esac
}
nexus_avoided() {   # nexus_avoided <component>: what a file of it that is never installed is
    case "$1" in
        A.G.I.S.) echo "another edition of A.G.I.S. than its main file, PUBLICNET" ;;
        No_Intro_Videos) echo "the redscript file of No Intro Videos, which hooks the game's start-up, where NightCoop skips the intro itself (take the archive file)" ;;
        *) h="$(nexus_file "$1")"; echo "another file of $(name_of "$1") than the one this script takes${h:+ ($h)}" ;;
    esac
}
cache_it() {   # cache_it <archive>: kept for later runs (not by a dry run)
    if [ "$DRY_RUN" != 1 ] && [ "$(dirname "$1")" != "$CACHE_DIR/mods" ] && mkdir -p "$CACHE_DIR/mods"; then
        cp "$1" "$CACHE_DIR/mods/$(basename "$1")" 2>/dev/null || true
    fi
}
unpack_any() {   # unpack_any <archive> <dir>: zip with the helper, 7z and rar with bsdtar (libarchive); prints why not
    local why
    case "${1,,}" in
        *.zip) why="$(py unzip "$1" "$2" 2>&1 >/dev/null)" && return 0 ;;
        *) if ! command -v bsdtar >/dev/null 2>&1; then echo "a .${1##*.} archive needs bsdtar (from libarchive) to unpack"; return 1; fi
           why="$(bsdtar -xf "$1" -C "$2" 2>&1 >/dev/null)" && return 0 ;;
    esac
    echo "${why##*$'\n'}"; return 1
}
newer_same_line() {   # newer_same_line <installed DLL> <our DLL> <rule>: the installed copy is newer and for this patch
    local a b
    a="$(pever "$1")"; b="$(pever "$2")"
    { [ -n "$a" ] && [ -n "$b" ] && ver_ge "$a" "$b" && ! ver_ge "$b" "$a"; } || return 1
    case "$3" in
        game) [ "$(py pestr "$1" ProductVersion)" = "$(py pestr "$2" ProductVersion)" ] ;;
        minor) [ "$(cut -d. -f1,2 <<<"$a")" = "$(cut -d. -f1,2 <<<"$b")" ] ;;
        *) return 1 ;;
    esac
}
step_addons() {   # the add-on sets (--with-flight, --with-mods), matched to the game patch
    local s w r on="" lines comp patch sets kind rule probe ver src sha id prefer avoid path which dir root files t inst ours e why n h v
    local -a cands found
    for s in flight mods eqex; do   # which sets are on this time: as recorded, unless an option says otherwise
        w=""
        for r in "${SET_WANT[@]}"; do if [ "${r:1}" = "$s" ]; then w="${r:0:1}"; fi; done
        if [ "$w" = + ] || { [ -z "$w" ] && [[ " $SETS_RECORDED " == *" $s "* ]]; }; then on+=" $s"; fi
        if [ "$w" = - ]; then
            if [[ " $SETS_RECORDED " == *" $s "* ]]; then SETS_DROPPED+=" $s"
            else info "--without-${s/eqex/equipment-ex}: this script has not installed $(set_label "$s"); nothing to remove"; fi
        fi
    done
    SETS_ON="${on# }"
    [ -n "$SETS_ON$SETS_RECORDED" ] || return 0
    bold "Add-ons${SETS_ON:+: ${SETS_ON// /, }}"
    lines="$(addon_lines)"
    while read -r comp; do if [ -n "$comp" ]; then ADDON_GONE+=("$(name_of "$comp")"); fi; done < <(gone_parts)
    if [ -z "$lines" ]; then   # a game patch the table does not know: what is there stays as it is
        warn "no add-on builds are known for game ${GAME_VER:-?}; what is installed is left as it is"
        if [ "${#ADDON_GONE[@]}" -gt 0 ]; then ok "$(listing "${ADDON_GONE[@]}") will be removed: no longer part of the set"; fi
        while read -r comp _; do keep_recorded "$comp"; done < <(addon_parts)
        SETS_ON="$SETS_RECORDED"
        return 0
    fi
    mkdir -p "$TMP/addons"
    while read -r comp patch sets kind rule probe ver src sha; do
        if ! in_sets_on "$sets"; then   # its sets are off: a lib stays as it is (no longer managed), a mod goes
            if [ -n "$(recorded_roots "$comp")" ]; then
                if [ "$kind" = lib ]; then while IFS= read -r r; do PROTECT+=("$r"); done < <(recorded_roots "$comp")
                else ADDON_DROP+=("$(name_of "$comp")"); fi
            fi
            continue
        fi
        if needs_pl "$comp" && ! has_pl; then ADDON_NOPL+=("$(name_of "$comp")"); continue; fi   # needs the expansion
        cands=()   # the archives to try, best first: path, version, and whether it is the preferred file
        case "$src" in
            nexus:*)   # the user's downloads, and the copies kept from earlier runs; ver: the oldest release for the patch
                IFS=: read -r _ id prefer avoid <<<"$src"
                mapfile -t found < <(py nexus-find "$id" "${prefer:--}" "${avoid:--}" "$ver" "${NEXUS_DIRS[@]}" "$CACHE_DIR/mods" || true)
                for e in "${found[@]}"; do
                    IFS=$'\x1f' read -r path v which <<<"$e"
                    case "$which" in
                        avoided) warn "$(basename "$path") is not installed: it is $(nexus_avoided "$comp")" ;;
                        old) warn "$(basename "$path") is $(name_of "$comp") $v; game ${GAME_VER:-?} needs $ver or newer (download the newest)" ;;
                        *) cands+=("$e") ;;
                    esac
                done
                if [ "${#cands[@]}" = 0 ]; then   # not downloaded yet: listed below; installed before: stays as it is
                    if [ -n "$(recorded_roots "$comp")" ]; then keep_recorded "$comp"; else ADDON_MISSING+=("$comp $id"); fi
                    continue
                fi ;;
            *)
                path="$CACHE_DIR/mods/$(basename "${src%%\?*}")"
                if ! { [ -f "$path" ] && sha_check "$path" "$sha"; }; then
                    path="$TMP/addons/$(basename "${src%%\?*}")"
                    download "$src" "$path" || fail "download failed: $src"
                    sha_check "$path" "$sha" || fail "SHA-256 mismatch for $(basename "$path") (expected $sha)"
                fi
                cands=("$path"$'\x1f'"$ver"$'\x1f'preferred) ;;
        esac
        for r in $(needs_of "$comp"); do   # everything it needs must be here, or it is left out
            if [ "$r" != Phantom_Liberty ] && [[ "$ADDON_HAVE" != *" $r "* ]]; then
                warn "$(name_of "$comp") needs $(name_of "$r"), which is not here; $(name_of "$comp") is left out"
                if [ -n "$(recorded_roots "$comp")" ]; then keep_recorded "$comp"; fi
                continue 2
            fi
        done
        root="" n=0
        for e in "${cands[@]}"; do   # the first that unpacks to game folders
            IFS=$'\x1f' read -r path ver which <<<"$e"
            ADDON_USED+="$(basename "$path") "
            n=$((n + 1)); dir="$TMP/addons/$comp.$n"; mkdir -p "$dir"
            if ! why="$(unpack_any "$path" "$dir")"; then warn "could not unpack $(basename "$path"): ${why:-unknown error}"; continue; fi
            find "$dir" -type l -delete   # nothing that points out of the game folder
            if root="$(py modroot "$dir" 2>/dev/null)"; then break; fi
            warn "$(basename "$path") has no game folders (r6, archive, bin, red4ext) in it"
        done
        if [ -z "$root" ]; then
            if [ -n "$(recorded_roots "$comp")" ]; then
                keep_recorded "$comp"; warn "keeping the installed $(name_of "$comp"): none of its downloads can be used"
            else warn "$(name_of "$comp") is left out: none of its downloads can be used (download it again, or install it by hand)"; fi
            continue
        fi
        if [ "$which" != preferred ]; then warn "$(basename "$path") does not look like the ${prefer} file of $(name_of "$comp"); using it anyway"; fi
        cache_it "$path"   # a usable archive only
        files="$TMP/addons/$comp.files"; mkdir -p "$files"
        for t in "$root"/*; do   # the game folders only: no read-me files, installer scripts or fomod data
            case "$(basename "$t" | tr '[:upper:]' '[:lower:]')" in archive|bin|engine|mods|r6|red4ext) cp -a "$t" "$files/" ;; esac
        done
        state_files "$comp" "$files"
        while IFS= read -r r; do ADDON_ROOTS+=("$comp"$'\t'"$r"); done < <(py roots "$files")
        inst="" ours=""
        if [ "$probe" != - ]; then
            inst="$(findci "$GAME_DIR" "$probe" 2>/dev/null || true)"; ours="$(findci "$files" "$probe" 2>/dev/null || true)"
        fi
        if [ "$rule" != - ] && [ -n "$inst" ] && [ -n "$ours" ] && newer_same_line "$inst" "$ours" "$rule"; then   # a newer copy for this patch stays
            mapfile -t cands < <(py roots "$files"); restage "${cands[@]}"
            ADDON_KEEP+=("$(name_of "$comp") $(pever "$inst" | cut -d. -f1-3)"); ADDON_HAVE+="$comp "
            ok "keeping the installed $(name_of "$comp") $(pever "$inst" | cut -d. -f1-3), which is newer than $ver and for the same patch"
            continue
        fi
        py merge "$files" "$TMP/stage"
        ADDON_PLAN+=("$(name_of "$comp") $ver"); ADDON_HAVE+="$comp "
        if [ -n "$ours" ]; then e="$(sha256sum "$ours" | cut -d' ' -f1)"; else e=-; fi
        ADDON_VERS+=("$comp"$'\t'"$ver"$'\t'"$e")
    done <<<"$lines"
    if [ "${#ADDON_PLAN[@]}" -gt 0 ]; then ok "for game ${GAME_VER:-?}: $(listing "${ADDON_PLAN[@]}")"; fi
    if [ "${#ADDON_DROP[@]}" -gt 0 ]; then ok "$(listing "${ADDON_DROP[@]}") will be removed; the frameworks they needed stay, since other mods use them"; fi
    if [ "${#ADDON_GONE[@]}" -gt 0 ]; then ok "$(listing "${ADDON_GONE[@]}") will be removed: no longer part of the set"; fi
    if [ "${#ADDON_NOPL[@]}" -gt 0 ]; then info "Phantom Liberty is not installed: $(listing "${ADDON_NOPL[@]}"), which need it, are left out"; fi
    if [[ "$ADDON_HAVE" == *" Quick_Stash "* ]]; then
        info "Quick Stash in co-op: a session plays in the host's world, so a guest's stash there is not their own;"
        info "transfer items in your own game, or as the host."
    fi
    if [[ "$ADDON_HAVE" == *" Virtual_Car_Dealer "* ]] || [[ "$ADDON_HAVE" == *" Drive_an_Aerial_Vehicle "* ]]; then
        info "Cars and AVs in co-op: partners see a car of a mod (one Virtual Car Dealer sells, an AV of Drive an"
        info "Aerial Vehicle) only when they have that mod too; otherwise NightCoop shows a game car with as many seats."
    fi
    local o outfit=0 layered=0
    for o in $ADDON_HAVE; do
        if [[ " ${OUTFITS//$'\n'/ } " == *" $o "* ]]; then outfit=1; fi
        if [ "$o" = Street_Ninja_Remake ]; then layered=1; fi
    done
    if [ "$outfit" = 1 ]; then
        info "Outfits of mods in co-op: a partner without the same outfit mod sees a plain game piece for that body"
        info "part (head, face and accessories stay empty), so share the outfit mods with everyone you play with."
    fi
    if [ "$layered" = 1 ] && [[ "$ADDON_HAVE" != *" Equipment_EX "* ]]; then
        info "Street Ninja's four layers are worn together with Equipment-EX (--with-equipment-ex); without it,"
        info "each piece takes its game slot on its own."
    fi
    local hair=0
    for o in $ADDON_HAVE; do if [[ " ${HAIRS//$'\n'/ } " == *" $o "* ]]; then hair=1; fi; done
    if [ "$hair" = 1 ]; then
        info "Hairstyles of mods in co-op: choose them in the character creator, at a mirror or at a ripperdoc. A partner"
        info "without the same hair mod sees your V without that hairstyle, so keep the mod set the same for everyone."
    fi
    if [[ "$ADDON_HAVE" == *" Nola_Mini_Dress "* ]] && [[ "$ADDON_HAVE" != *" Nola_Virtual_Boutique "* ]]; then   # her boutique sells it
        info "No store of the set sells Nola Dreamer's mini dress: add it in Cyber Engine Tweaks' console"
        info "(Game.AddToInventory), with the codes listed on its Nexus Mods page."
    fi
    if [[ "$ADDON_HAVE" == *" Equipment_EX "* ]]; then
        info "Equipment-EX in co-op: every partner needs it too. NightCoop sends looks by its slots, so a partner"
        info "without it sees other slots; NightCoop also notes that it overrides photo-mode functions."
    fi
    if [[ "$ADDON_HAVE" == *" VendorsXL "* ]]; then
        info "VendorsXL changes how every vendor restocks (larger stock limits). The RVC00N Dumpster 3's shop is"
        info "behind Dakota's garage; the computer next to it sells the whole catalogue."
    fi
    if [[ "$ADDON_HAVE" == *" Vehicle_Customizer "* ]]; then
        info "Vehicle Customizer works only with the game's language set to English."
    fi
    if [ "${#ADDON_MISSING[@]}" -gt 0 ]; then
        warn "not found in $(listing "${NEXUS_DIRS[@]}"): these are published only on Nexus Mods, which does not allow"
        warn "downloads by scripts. Download them there (a free account is enough), then run this again:"
        for e in "${ADDON_MISSING[@]}"; do
            read -r comp id <<<"$e"; h="$(nexus_file "$comp")"
            info "    $(name_of "$comp")${h:+ ($h)}: https://www.nexusmods.com/cyberpunk2077/mods/$id?tab=files"
        done
    fi
    if [ "$DRY_RUN" != 1 ] && [ -d "$CACHE_DIR/mods" ]; then   # the cache keeps what this run uses
        for path in "$CACHE_DIR/mods"/*; do [[ "$ADDON_USED" == *" $(basename "$path") "* ]] || rm -f "$path"; done
    fi
    return 0
}

release_of() {   # release_of <component> <file>: the release this script recorded for it, else what the file says
    local sha e c v h
    sha="$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)"
    for e in "${VERS_REC[@]}"; do
        IFS=$'\t' read -r c v h <<<"$e"
        if [ "$c" = "$1" ] && { [ "$h" = - ] || [ "$h" = "$sha" ]; }; then echo "$v"; return 0; fi
    done
    [ -f "$2" ] && pever "$2" | cut -d. -f1-3
    return 0
}
addon_rows() {   # check: each add-on set
    local set comp sets kind rule probe d v mods libs missing alt q ok
    for set in flight mods eqex; do
        mods=() libs=() missing=()
        while read -r comp sets kind rule probe; do
            if [[ ",$sets," != *",$set,"* ]]; then   # "mods+eqex" shows with eqex, when all its sets are on
                ok=0
                for alt in ${sets//,/ }; do
                    [[ "$alt" == *"+$set" ]] || continue
                    ok=1; for q in ${alt//+/ }; do [[ " $SETS_RECORDED " == *" $q "* ]] || ok=0; done
                done
                [ "$ok" = 1 ] || continue
            fi
            if needs_pl "$comp" && ! has_pl; then continue; fi
            if [ "$probe" != - ]; then d="$(findci "$GAME_DIR" "$probe" 2>/dev/null || true)"; else d="$(present_root "$comp")"; fi
            if [ -z "$d" ]; then missing+=("$(name_of "$comp")"); continue; fi
            v="$(release_of "$comp" "$d")"
            if [ "$kind" = mod ]; then mods+=("$(name_of "$comp")${v:+ $v}"); else libs+=("$(name_of "$comp")${v:+ $v}"); fi
        done < <(addon_parts)
        if [ "$set" = flight ]; then
            v="${mods[0]:-}"; v="${v#Let There Be Flight}"; v="${v# }"
            if [[ " $SETS_RECORDED " == *" flight "* ]]; then
                row "Let There Be Flight" "${v:-missing}, with $(listing "${libs[@]:-nothing}") (kept up to date by this script)"
            elif [ -n "$v" ]; then row "Let There Be Flight" "$v (installed by hand; --with-flight keeps it and what it needs up to date)"
            else row "Let There Be Flight" "not installed; NightCoop supports it in co-op (add --with-flight)"; fi
        elif [ "$set" = eqex ]; then
            if [[ " $SETS_RECORDED " == *" eqex "* ]]; then row "Equipment-EX" "$(listing "${mods[@]:-missing}") (kept up to date by this script)"
            else row "Equipment-EX" "not installed by this script (add --with-equipment-ex to wear layered outfits)"; missing=(); fi
        elif [[ " $SETS_RECORDED " == *" mods "* ]]; then
            row "Mods" "$(listing "${mods[@]:-none yet}"), with $(listing "${libs[@]:-nothing}") (kept up to date by this script)"
        else
            row "Mods" "not installed by this script (add --with-mods)"; missing=()
        fi
        if [ "${#missing[@]}" -gt 0 ] && [[ " $SETS_RECORDED " == *" $set "* ]]; then
            warn "missing: $(listing "${missing[@]}"); run '$0 update' to install them (it lists what to download)"
        fi
    done
}

pick_vcredist() {   # sets VCREDIST and VCREDIST_VER to the newest installer at hand
    local c v best="" bestv="" lib cache="$CACHE_DIR/vc_redist.x64.exe" url
    vc_ok() { [[ "$(py pestr "$1" FileDescription)$(py pestr "$1" ProductName)" == *"Visual C++"* ]] && ver_ge "$(pever "$1")" 14.0; }
    consider() { v="$(pever "$1")"; if [ -n "$v" ] && { [ -z "$bestv" ] || ! ver_ge "$bestv" "$v"; }; then best="$1"; bestv="$v"; fi; }
    if [ -n "$VCREDIST" ]; then
        if [ ! -f "$VCREDIST" ] || ! vc_ok "$VCREDIST"; then fail "$VCREDIST is not a Visual C++ redistributable installer"; fi
        consider "$VCREDIST"
    else
        for lib in "${LIBS[@]}"; do
            for c in "$lib/steamapps/common/Steamworks Shared/_CommonRedist/vcredist"/*/VC_redist.x64.exe; do
                if [ -f "$c" ] && vc_ok "$c"; then consider "$c"; fi
            done
        done
        if [ -f "$cache" ] && vc_ok "$cache"; then consider "$cache"; fi
        if { [ -z "$bestv" ] || ! ver_ge "$bestv" "$RT_WANT"; } && ! { [ -f "$cache" ] && [ -n "$(find "$cache" -mtime -7 2>/dev/null)" ]; }; then
            if [ "$DRY_RUN" = 1 ]; then
                VCREDIST="${VCREDIST_URLS[0]}"; VCREDIST_VER="newest from Microsoft"; return 0
            else
                mkdir -p "$CACHE_DIR"
                for url in "${VCREDIST_URLS[@]}"; do
                    if download "$url" "$cache.part" && vc_ok "$cache.part"; then mv -f "$cache.part" "$cache"; consider "$cache"; break; fi
                    rm -f "$cache.part"; warn "no usable installer from $url"
                done
            fi
        fi
    fi
    VCREDIST="$best"; VCREDIST_VER="$bestv"
}

step_runtime() {
    bold "Microsoft Visual C++ runtime in the Proton prefix"
    local crt who
    local -a extra=()
    if [ "$R4_CHOICE" = installed ]; then
        extra=("$(findci "$GAME_DIR" red4ext/RED4ext.dll)" "$(findci "$GAME_DIR" bin/x64/winmm.dll)")
    fi
    IFS=$'\x1f' read -r crt who < <(py pecrt "$TMP/stage" "${extra[@]}") || true
    RT_WANT="$RUNTIME_FLOOR"; [ -n "$crt" ] && ver_ge "$crt" "$RT_WANT" && RT_WANT="$crt"
    RV="$(runtime_version)"; RK="$(runtime_kind)"
    if [ "$RK" = builtin ]; then
        info "the mod's DLLs are built with MSVC ${crt:-unknown}${who:+ ($who)}; the prefix has Wine's built-in runtime"
        info "that works, but Steam's redistributable step can put Microsoft's 2019 runtime in its place (error 998); the current one prevents that"
        RV=""
    else
        info "the mod's DLLs are built with MSVC ${crt:-unknown}${who:+ ($who)}; the prefix has ${RV:-no msvcp140.dll}"
        if [ -n "$RV" ] && ver_ge "$RV" "$RT_WANT"; then ok "runtime $RV is new enough"; return 0; fi
    fi
    pick_vcredist
    if [ "$DRY_RUN" = 1 ] && [[ "$VCREDIST" == *://* ]]; then
        NEED_RT=1; RT_TARGET="$RT_WANT"; info "(dry run) would download the newest runtime from Microsoft"; return 0
    fi
    if [ -z "$VCREDIST" ]; then
        if [ -n "$RV" ] && ver_ge "$RV" "$RUNTIME_FLOOR"; then warn "no installer available; keeping runtime $RV, which usually works"; return 0; fi
        fail "no Visual C++ runtime installer available; download VC_redist.x64.exe from Microsoft and pass --vcredist FILE"
    fi
    if [ -n "$RV" ] && ver_ge "$RV" "$VCREDIST_VER"; then
        if ver_ge "$RV" "$RUNTIME_FLOOR"; then ok "runtime $RV is the newest Microsoft offers right now; it works with builds from MSVC $RT_WANT"
        else warn "runtime $RV is too old and no newer installer is available"; fi
        return 0
    fi
    NEED_RT=1
    RT_TARGET="$RT_WANT"; ver_ge "$VCREDIST_VER" "$RT_WANT" || RT_TARGET="$VCREDIST_VER"
    ok "installer: ${VCREDIST} ($VCREDIST_VER)"
    [ -n "$PROTON_DIR" ] || warn "no Proton build found to run it with; the runtime step will be skipped"
}

steam_settings_note() {   # how a Steam setting will be written, for the plan
    if ! steam_running; then return 0; fi
    if [ "$CLOSE_STEAM" = 1 ]; then
        in_game_mode && fail "--close-steam would end the Game Mode session; run this from Desktop Mode"
        steam_launcher_ok || fail "--close-steam: the steam command was not found in PATH"
        info "Steam will be closed and reopened to write it"
    else
        info "Steam is running, so it will not be written (close Steam or use --close-steam; the steps are shown at the end)"
    fi
}

step_override() {
    bold "DLL overrides and launch options"
    DLLS="$(dll_overrides)"
    [ "$DLLS" = winmm ] || info "Cyber Engine Tweaks found (bin/x64/version.dll); its loader gets the same override"
    REG_STATE="$(reg_state "$DLLS")"
    case "$REG_STATE" in
        ok) ok "prefix registry already has $DLLS = native,builtin" ;;
        missing) info "prefix registry: will add $DLLS = native,builtin for Cyberpunk2077.exe (works while Steam is open)" ;;
        *) warn "the prefix has no user.reg; relying on the launch options" ;;
    esac
    IFS=$'\x1f' read -r LO_STATE LO_VALUE LO_WINMM < <(py lo-status "$STEAM_ROOT" "$APPID" "$DLLS" "$GAME_ARGS") || LO_STATE=nofile
    if [ "$LO_STATE" != nofile ]; then
        wrap_plan "$LO_VALUE"; wrap_notes
        IFS=$'\x1f' read -r LO_STATE LO_VALUE LO_WINMM < <(py lo-status "$STEAM_ROOT" "$APPID" "$DLLS" "$GAME_ARGS" "$WRAP") || LO_STATE=nofile
    fi
    case "$LO_STATE" in
        ok) ok "launch options already set: $LO_VALUE" ;;
        nofile) warn "Steam's per-user config was not found; launch options cannot be checked" ;;
        *) info "launch options: will be set to $(py lo-merge "$LO_VALUE" "$DLLS" "$GAME_ARGS" "$WRAP" | cut -d$'\x1f' -f2)"
           [ -z "$GAME_ARGS" ] || info "(--launcher-skip starts the game without CDPR's launcher window; --no-launcher-skip keeps it)"
           steam_settings_note ;;
    esac
}

step_proton_tool() {
    bold "Proton build for the game"
    local cur def now
    IFS=$'\x1f' read -r cur def < <(py ct-get "$STEAM_ROOT" "$APPID") || true
    now="$cur"; [ -n "$now" ] || now="Steam's default${def:+ ($def)}"
    if [ "$PROTON_WANT" = keep ]; then
        info "left as it is (--proton keep): $now"; return 0
    fi
    IFS=$'\x1f' read -r TOOL_NAME TOOL_DIR TOOL_REASON TOOL_LABEL < <(py ct-pick "$STEAM_ROOT" "$PROTON_WANT" "$OS_FAMILY" "${LIBS[@]}") \
        || fail "--proton $PROTON_WANT cannot be used (see the message above)"
    TOOL_LABEL="${TOOL_LABEL:-$TOOL_NAME}"
    if [ "$TOOL_NAME" = "$cur" ]; then ok "$TOOL_LABEL ($TOOL_REASON)"; TOOL_STATE=ok; return 0; fi
    TOOL_STATE=pending
    info "will choose $TOOL_LABEL ($TOOL_REASON); now: $now"
    if [ -z "$TOOL_DIR" ]; then info "Steam downloads it the next time the game starts"
    else info "Steam updates the prefix to it on the next start; the runtime installed here is kept"; fi
    steam_settings_note
}

plan_files() {   # PLAN_*: what copying the staged files would change in the game folder
    local plan line
    plan="$(py tree-plan "$TMP/stage" "$GAME_DIR" "${PREV_BACKUP:+$PREV_BACKUP/manifest.tsv}" "$NC_PLUGIN_DIR" "$FORCE" "${PROTECT[@]}")" \
        || fail "the game folder cannot take the new files (see above)"
    IFS=$'\x1f' read -r PLAN_ADDED PLAN_REPLACED PLAN_REMOVED PLAN_SAME <<<"${plan%%$'\n'*}"
    PLAN_STALE=()
    while IFS=$'\x1f' read -r _ line; do [ -z "$line" ] || PLAN_STALE+=("$line"); done < <(tail -n +2 <<<"$plan")
    FILES_CHANGE=0; [ $((PLAN_ADDED + PLAN_REPLACED + PLAN_REMOVED)) = 0 ] || FILES_CHANGE=1
    # dropping a set always writes a manifest without its mods: otherwise the next run would
    # read the frameworks left in place as leftovers of the previous install and remove them
    [ "${#ADDON_DROP[@]}" = 0 ] || FILES_CHANGE=1
    PREFIX_CHANGE=0; { [ "$NEED_RT" = 1 ] || [ "$REG_STATE" = missing ]; } && PREFIX_CHANGE=1
    STEAM_CHANGE=0; { [ "$LO_STATE" = missing ] || [ "$LO_STATE" = broken ] || [ "$TOOL_STATE" = pending ]; } && STEAM_CHANGE=1
    return 0
}

print_plan() {
    echo
    bold "Plan"
    local later="" same=""
    steam_running && [ "$CLOSE_STEAM" != 1 ] && later=" (when Steam is closed)"
    if [ "$FILES_CHANGE" = 1 ] || [ "$PREFIX_CHANGE" = 1 ]; then
        if [ -d "$SAVES" ]; then
            if [ "$SAVE_BACKUP" = 1 ]; then info "back up saves   -> $BACKUP/Saved Games ($(du -sh "$SAVES" 2>/dev/null | cut -f1))"
            elif [ -n "$SAVE_AUTO" ]; then info "saves           not copied on an update (add --backup-saves to copy them)"
            else info "saves           not copied (--no-save-backup)"; fi
        fi
        info "back up files   -> $BACKUP"
    fi
    if [ "$FILES_CHANGE" = 1 ]; then
        if [ -n "$NC_PRESENT" ] && [ "${NC_INSTALLED:-}" != "${NC_VER:-}" ]; then
            local from="${NC_INSTALLED:-${NC_RECORDED:+$NC_RECORDED, changed since it was installed}}"
            info "update          NightCoop ${from:-(a build this script did not install)} -> ${NC_VER:-?}"
        fi
        [ "$PLAN_SAME" = 0 ] || same=", $PLAN_SAME already up to date"
        info "install         NightCoop ${NC_VER:-?}${ADDON_PLAN:+ and the add-ons}: $PLAN_ADDED new, $PLAN_REPLACED replaced file(s) in the game folder$same"
        [ "$PLAN_REMOVED" = 0 ] || info "remove          $PLAN_REMOVED file(s) of the previous build: ${PLAN_STALE[*]}"
        info "RED4ext         $R4_FINAL ($R4_CHOICE)"
        if [ "${#ADDON_PLAN[@]}" -gt 0 ]; then info "add-ons         $(listing "${ADDON_PLAN[@]}") (for game ${GAME_VER:-?})"; fi
        if [ "${#ADDON_KEEP[@]}" -gt 0 ]; then info "keep            $(listing "${ADDON_KEEP[@]}") (installed, newer)"; fi
        if [ "${#ADDON_DROP[@]}" -gt 0 ]; then info "remove          $(listing "${ADDON_DROP[@]}"); the frameworks they needed stay"; fi
        if [ "${#ADDON_GONE[@]}" -gt 0 ]; then info "remove          $(listing "${ADDON_GONE[@]}") (no longer part of the set)"; fi
    fi
    [ "$NEED_RT" = 1 ] && info "run             VC_redist.x64.exe ${VCREDIST_VER} quietly in the game's Proton prefix"
    [ "$REG_STATE" = missing ] && info "registry        $DLLS = native,builtin for Cyberpunk2077.exe"
    if [ "$LO_STATE" = missing ] || [ "$LO_STATE" = broken ]; then
        info "launch options  $(py lo-merge "$LO_VALUE" "$DLLS" "$GAME_ARGS" "$WRAP" | cut -d$'\x1f' -f2)$later"
    fi
    [ "$TOOL_STATE" = pending ] && info "Proton          $TOOL_LABEL for Cyberpunk 2077$later"
    return 0
}

run_in_prefix() {   # run_in_prefix direct|slr <windows exe> [args...]
    local how="$1"; shift
    local libpaths; libpaths="$(IFS=:; echo "${LIBS[*]}")"
    # runinprefix runs the program with Proton's Wine directly. "run" goes through Proton's
    # steam.exe, which needs Steam's client library and fails without it.
    local verb=run
    grep -q '"runinprefix"' "$PROTON_DIR/proton" 2>/dev/null && verb=runinprefix
    local -a cmd=("$PROTON_DIR/proton" "$verb" "$@")
    [ "$how" = slr ] && cmd=("$SLR_ENTRY" --verb=waitforexitandrun -- "$PROTON_DIR/proton" "$verb" "$@")
    env STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" STEAM_COMPAT_DATA_PATH="$COMPAT" \
        STEAM_COMPAT_INSTALL_PATH="$GAME_DIR" STEAM_COMPAT_LIBRARY_PATHS="$libpaths" \
        STEAM_COMPAT_APP_ID="$APPID" SteamAppId="$APPID" SteamGameId="$APPID" \
        PRESSURE_VESSEL_FILESYSTEMS_RO="$(dirname "$1")" PROTONFIXES_DISABLE=1 \
        timeout 900 "${cmd[@]}"
}

apply_runtime() {
    [ "$NEED_RT" = 1 ] && [ -n "$PROTON_DIR" ] || return 0
    bold "Installing the Visual C++ runtime into the prefix"
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || warn "no graphical session found (DISPLAY is unset); if the installer fails, run this from a desktop terminal (Steam Deck: Desktop Mode > Konsole)"
    info "running the Microsoft installer with $(proton_label); this takes a minute or two"
    local how rc
    for how in direct slr; do
        if [ "$how" = slr ]; then
            [ -n "$SLR_ENTRY" ] || break
            info "retrying inside the Steam Linux Runtime ($(basename "$(dirname "$SLR_ENTRY")"))"
        fi
        rc=0; run_in_prefix "$how" "$VCREDIST" /install /quiet /norestart >>"$BACKUP/vcredist.log" 2>&1 || rc=$?
        wait_prefix_idle 60 || true
        case "$rc" in
            0) ;; 194) info "the installer asked for a reboot (Windows code 3010); not needed under Proton" ;;
            102) info "the installer reports a newer runtime is already registered (code 1638)" ;;
            124) warn "the installer timed out" ;; *) warn "the installer exited with code $rc" ;;
        esac
        RV="$(runtime_version)"
        if [ -n "$RV" ] && ver_ge "$RV" "$RT_TARGET"; then ok "prefix runtime is now $RV"; return 0; fi
    done
    warn "the prefix runtime is still ${RV:-missing} (log: $BACKUP/vcredist.log)"
    protontricks_hint
}

protontricks_hint() {
    info "Fallback: install the runtime with protontricks, then run '$0 check':"
    case "$OS_FAMILY" in
        steamos)
            info "  1. Desktop Mode > Discover: install \"Protontricks\" (Flathub)"
            info "  2. flatpak run com.github.Matoking.protontricks $APPID --force vcrun2022"
            info "  If the game is on an SD card, first: flatpak override --user --filesystem=/run/media com.github.Matoking.protontricks" ;;
        cachyos|arch|archlike)
            info "  paru -S protontricks   (any AUR helper; or Flathub com.github.Matoking.protontricks)"
            info "  protontricks $APPID --force vcrun2022" ;;
        *)
            info "  protontricks $APPID --force vcrun2022   (Flathub: com.github.Matoking.protontricks)" ;;
    esac
}

close_steam() {
    if [ "$STEAM_KIND" = flatpak ]; then flatpak run com.valvesoftware.Steam -shutdown >/dev/null 2>&1 &
    else steam -shutdown >/dev/null 2>&1 & fi
    local _
    for _ in $(seq 1 60); do steam_running || return 0; sleep 1; done
    return 1
}
start_steam() {
    if [ "$STEAM_KIND" = flatpak ]; then setsid -f flatpak run com.valvesoftware.Steam >/dev/null 2>&1 </dev/null || warn "could not reopen Steam"
    else setsid -f steam >/dev/null 2>&1 </dev/null || warn "could not reopen Steam"; fi
}
steam_launcher_ok() { if [ "$STEAM_KIND" = flatpak ]; then command -v flatpak >/dev/null 2>&1; else command -v steam >/dev/null 2>&1; fi; }

apply_steam_settings() {
    local need=0 f res
    case "$LO_STATE" in missing|broken) need=1 ;; esac
    [ "$TOOL_STATE" = pending ] && need=1
    [ "$need" = 1 ] || return 0
    if steam_running; then
        [ "$CLOSE_STEAM" = 1 ] || return 0
        bold "Closing Steam to write its settings"
        if close_steam; then RESTART_STEAM=1; else warn "Steam did not close within a minute; its settings were not written"; return 0; fi
    fi
    if [ "$TOOL_STATE" = pending ]; then
        bold "Choosing the Proton build"
        mkdir -p "$BACKUP"   # the earlier choice, for reference (restore leaves Steam's settings alone)
        py ct-get "$STEAM_ROOT" "$APPID" | cut -d$'\x1f' -f1 > "$BACKUP/compat-tool.txt"
        if py ct-set "$STEAM_ROOT" "$APPID" "$TOOL_NAME" >/dev/null && [ "$(py ct-get "$STEAM_ROOT" "$APPID" | cut -d$'\x1f' -f1)" = "$TOOL_NAME" ]; then
            TOOL_STATE=ok; ok "Cyberpunk 2077 > Properties > Compatibility: $TOOL_LABEL"
        else warn "could not write the compatibility tool to Steam's config.vdf"; fi
    fi
    case "$LO_STATE" in missing|broken) ;; *) return 0 ;; esac
    bold "Writing Steam launch options"
    if [ -n "$LO_VALUE" ]; then   # the script writes the whole line: the earlier one, for reference
        mkdir -p "$BACKUP" && printf '%s\n' "$LO_VALUE" > "$BACKUP/launch-options.txt"
        info "the launch options are replaced as a whole; the earlier ones are kept in $BACKUP/launch-options.txt"
    fi
    while IFS=$'\x1f' read -r f res; do info "user $(basename "$(dirname "$(dirname "$f")")"): $res"; done \
        < <(py lo-set "$STEAM_ROOT" "$APPID" "$DLLS" "$GAME_ARGS" "$WRAP")
    IFS=$'\x1f' read -r LO_STATE LO_VALUE LO_WINMM < <(py lo-status "$STEAM_ROOT" "$APPID" "$DLLS" "$GAME_ARGS" "$WRAP") || true
    if [ "$LO_STATE" = ok ]; then ok "launch options set"; else warn "could not set the launch options automatically"; fi
}

print_followups() {   # what is left to set in Steam by hand
    local merged; merged="$(py lo-merge "$LO_VALUE" "$DLLS" "$GAME_ARGS" "$WRAP" | cut -d$'\x1f' -f2)"
    if [ "$REG_STATE" != ok ] && [ "${LO_WINMM:-}" != ok ]; then
        bold "One manual step left"
        info "In Steam: right-click Cyberpunk 2077 > Properties > General > Launch Options, and enter:"
        echo; info "    $merged"; echo
        info "Without it Proton ignores RED4ext's loader and the mod never starts."
    elif [ "$LO_STATE" != ok ] && [ "$LO_STATE" != nofile ]; then
        info "Recommended (the prefix override already lets the mod load): in Steam, right-click"
        info "Cyberpunk 2077 > Properties > General > Launch Options, and enter:"
        info "    $merged"
    fi
    if [ "$TOOL_STATE" = pending ]; then
        info "Recommended: in Steam, right-click Cyberpunk 2077 > Properties > Compatibility, tick"
        info "\"Force the use of a specific Steam Play compatibility tool\" and choose $TOOL_LABEL."
    fi
    return 0
}

game_too_old() { [ -n "$GAME_FILEVER" ] && ! ver_ge "$GAME_FILEVER" "$MIN_GAME_FILEVER"; }
do_install() {
    game_running && fail "Cyberpunk 2077 is running. Quit it and run this again."
    if game_too_old; then
        fail "Cyberpunk 2077 ${GAME_VER:-$GAME_FILEVER} is older than patch $MIN_GAME_PATCH, the oldest this installer supports. Update the game in Steam (Properties > Updates), start it once, then run this again."
    fi
    [ -n "$COMPAT" ] || { no_prefix_help; exit 1; }
    STAMP="$(date +%Y-%m-%d-%H%M%S)"; BACKUP="$BACKUP_ROOT/$STAMP"
    PREV_BACKUP="$(latest_backup)"
    # The saves are copied on the first install. Later runs leave them to that copy unless
    # --backup-saves asks for another: an update does not touch them, and they can be GBs.
    if [ -z "$SAVE_BACKUP" ]; then
        SAVE_AUTO=1; if [ -n "$PREV_BACKUP" ]; then SAVE_BACKUP=0; else SAVE_BACKUP=1; fi
    fi
    [ -n "$PREV_BACKUP" ] && [ ! -f "$PREV_BACKUP/manifest.tsv" ] && PREV_BACKUP=""
    NC_PRESENT="$(nc_dll)"
    PROTECT=("${RED4EXT_CORE[@]}")

    step_nightcoop
    step_stage
    step_red4ext
    step_addons
    step_runtime
    step_override
    step_proton_tool
    plan_files
    if [ "$FILES_CHANGE" = 0 ] && [ "$PREFIX_CHANGE" = 0 ]; then   # an update with nothing new
        echo
        ok "all $PLAN_SAME files of NightCoop ${NC_VER:-?} (with RED4ext $R4_FINAL${ADDON_PLAN:+ and the add-ons}) are already in place; nothing to replace (--force reinstalls them)"
        if [ "$DRY_RUN" != 1 ] && { [ "${NC_INSTALLED:-}" != "${NC_VER:-}" ] || ! grep -q '^dll_sha256' "$DATA_DIR/installed.tsv" 2>/dev/null \
                || [ "$(addon_record_lines)" != "$(addon_record_lines recorded)" ]; }; then
            record_install "${NC_VER:-}" "${NC_PROTO:-}" "${NC_GAMES:-}" "$R4_FINAL" ""
            info "recorded as the installed build, for later update checks"
        fi
        if [ "$STEAM_CHANGE" = 0 ]; then save_settings; ok "everything is up to date; nothing to do"; return 0; fi
        if steam_running && [ "$CLOSE_STEAM" != 1 ]; then save_settings; echo; print_followups; return 0; fi
    fi
    print_plan
    if [ "$DRY_RUN" = 1 ]; then echo; ok "dry run finished; nothing was changed"; return 0; fi
    echo
    confirm "Go ahead?" || { info "aborted"; exit 1; }
    save_settings

    if [ "$FILES_CHANGE" = 1 ] || [ "$PREFIX_CHANGE" = 1 ]; then
        bold "Backing up"
        mkdir -p "$BACKUP/game"
        printf 'created\t%s\nscript\t%s\ngame_dir\t%s\nprefix\t%s\nnightcoop\t%s\nred4ext\t%s\n' \
            "$(date -Is)" "$SCRIPT_VERSION" "$GAME_DIR" "$COMPAT" "${NC_VER:-unknown}" "$R4_FINAL" > "$BACKUP/info.tsv"
        if [ "$SAVE_BACKUP" = 1 ] && [ -d "$SAVES" ]; then
            local need avail
            need="$(du -sb "$SAVES" | cut -f1)"; avail="$(df -B1 --output=avail "$BACKUP" | tail -n1 | tr -d ' ')"
            if [ "$need" -lt $((avail - 1073741824)) ]; then
                cp -a --reflink=auto "$SAVES" "$BACKUP/Saved Games"
                ok "saves copied ($(human "$need"), $(find "$BACKUP/Saved Games" -mindepth 1 -maxdepth 1 | wc -l) entries)"
            else
                warn "not enough free space to copy the saves ($(human "$need") needed); skipped"
            fi
        fi
        if [ "$NEED_RT" = 1 ]; then
            mkdir -p "$BACKUP/prefix-runtime"
            find "$SYS32" -maxdepth 1 -type f \( -iname 'msvcp140*.dll' -o -iname 'vcruntime140*.dll' -o -iname concrt140.dll -o -iname vccorlib140.dll \) \
                -exec cp -a {} "$BACKUP/prefix-runtime/" \;
        fi
        [ -f "$USERREG" ] && cp -a "$USERREG" "$BACKUP/user.reg"

        # Runs even when no file changes: its manifest is what restore and later updates read.
        if [ "$FILES_CHANGE" = 1 ]; then bold "Installing NightCoop and RED4ext"; else bold "Game folder (no file changes)"; fi
        local added replaced removed same
        IFS=$'\x1f' read -r added replaced removed same < <(py tree-apply "$TMP/stage" "$GAME_DIR" "$BACKUP/game" \
            "$BACKUP/manifest.tsv" "${PREV_BACKUP:+$PREV_BACKUP/manifest.tsv}" "$NC_PLUGIN_DIR" "$FORCE" "${PROTECT[@]}") \
            || fail "copying into the game folder failed; undo with: $0 restore \"$BACKUP\""
        ok "$added added, $replaced replaced, $removed stale removed, $same unchanged; backup: $BACKUP"
        local r4; r4="$(red4ext_core_version "$GAME_DIR")"
        if [ -n "$r4" ] && ver_ge "$r4" "$R4_FINAL"; then ok "RED4ext $r4 in place"; else fail "RED4ext reports '${r4:-nothing}' after the install"; fi

        if [ "$REG_STATE" = missing ]; then
            bold "Adding the DLL override to the prefix registry"
            wait_prefix_idle 30 || fail "Wine is still running in the game's prefix (wineserver $(py wsrv "$PFX" | tr '\n' ' ')); close it and run again"
            local prev had d
            : > "$BACKUP/registry.tsv"
            for d in $(tr ',' ' ' <<<"$DLLS"); do
                had=0; if prev="$(py reg-get "$USERREG" "$REG_KEY" "$d")"; then had=1; else prev=""; fi
                printf '%s\t%s\t%s\t%s\n' "$had" "$REG_KEY" "$d" "$prev" >> "$BACKUP/registry.tsv"
                py reg-set "$USERREG" "$REG_KEY" "$d" native,builtin
            done
            ok "HKCU\\$REG_KEY: $DLLS = native,builtin"
        fi
        apply_runtime
    fi
    apply_steam_settings
    REG_STATE="$(reg_state "$DLLS")"

    record_install "${NC_VER:-}" "${NC_PROTO:-}" "${NC_GAMES:-}" "$R4_FINAL" "$BACKUP"
    [ "$RESTART_STEAM" = 1 ] && { info "reopening Steam"; start_steam; }

    echo
    bold "Done"
    do_check
    echo
    print_followups
    if [[ " $SETS_ON " != *" flight "* ]] && [[ " $SETS_DROPPED " != *" flight "* ]]; then
        info "Optional: NightCoop supports flying cars in co-op with Let There Be Flight. Add --with-flight"
        info "to install it with what it needs; every player in a session should have it."
    fi
    echo
    if [ "$OS_FAMILY" = steamos ]; then
        info "Return to Game Mode (or stay in Desktop Mode) and launch Cyberpunk 2077 from Steam."
    else
        info "Launch Cyberpunk 2077 from Steam."
    fi
    cat <<EOF
  The main menu should show a Co-op entry ("Совместная игра" in Russian builds).
  If it does not, run:  $0 check
EOF
    if [ -f "$BACKUP/manifest.tsv" ]; then
        printf '\n  Backups of everything replaced are in: %s\n  To undo this install:  %s restore\n' "$BACKUP" "$0"
    fi
}

# ------------------------------------------------------------------- main ----
cleanup() { if [ -n "${TMP:-}" ]; then rm -rf "$TMP"; fi; }
main() {
    [ "$(id -u)" != 0 ] || [ "${NIGHTCOOP_ALLOW_ROOT:-0}" = 1 ] || fail "run this as your normal user, not root (no sudo needed)"
    [ -n "${HOME:-}" ] && [ -d "$HOME" ] || fail "HOME is not set"
    detect_os
    need_tools
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/nightcoop.XXXXXX")"; trap cleanup EXIT

    bold "System"
    ok "$OS_NAME${DEVICE:+ on a $DEVICE}"
    [ "$OS_FAMILY" = other ] && info "not SteamOS, CachyOS or Arch; using the generic Linux path"
    if [ "${#NEXUS_DIRS[@]}" = 0 ]; then   # the Downloads folder (xdg-user-dir names the home folder when none is set)
        local dl; dl="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
        if [ -z "$dl" ] || [ "$(readlink -m "$dl")" = "$(readlink -m "$HOME")" ]; then dl="$HOME/Downloads"; fi
        NEXUS_DIRS=("$dl")
    fi
    locate_game
    read_installed
    if ! locate_prefix && [ "$MODE" = check ]; then warn "no Proton prefix yet (launch the game once)"; fi
    [ -n "$COMPAT" ] && locate_proton

    case "$MODE" in
        check)     do_check ;;
        restore)   do_restore ;;
        uninstall) do_uninstall ;;
        install)   do_install ;;
    esac
}
NC_INSTALLED="" NC_RECORDED="" LATEST_STATUS="" LATEST_VER="" SETS_RECORDED="" ROOTS_REC=() VERS_REC=() STATE_REC=()
main
