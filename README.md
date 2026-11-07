# NightCoop on Arch Linux and SteamOS

[NightCoop](https://nightcoop.net/) is an unofficial co-op mod for Cyberpunk 2077, and
its site supports Windows only. The mod runs well under Proton, but three problems stop
it from loading out of the box. `nightcoop-install.sh` fixes all three, installs the mod
and sets up Proton for the game on SteamOS (Steam Deck), CachyOS and other Arch-based
systems. It can also install popular mods chosen to work alongside NightCoop (see
[Other mods](#other-mods)).

## Supported systems

| System | Notes |
| --- | --- |
| **SteamOS 3** (Steam Deck LCD and OLED, other SteamOS devices) | Run from Desktop Mode. Games on an SD card are found. Nothing is installed into the read-only system, and Steam may stay open. |
| **CachyOS** | Uses `proton-cachyos` when it is installed, otherwise Proton Experimental. Keeps launch options such as `game-performance %command%`. Installable as a pacman package. |
| **Arch Linux** and derivatives (EndeavourOS, Manjaro, Garuda, …) | Steam from `[multilib]`. Installable as a pacman package. |
| **Flatpak Steam** (any distribution) | Detected automatically. |
| Bazzite and other distributions | Same code path. |

The game must be the Steam version of Cyberpunk 2077 at **patch 2.5 or newer**. The script
refuses older patches; update the game in Steam first.

## Quick start

First, on any system: **launch Cyberpunk 2077 once through Steam, wait for the main
menu, and quit.** This creates the Proton prefix the script works on.

### Steam Deck and SteamOS

1. Switch to Desktop Mode: press the Steam button, then select Power > Switch to Desktop.
2. Open **Konsole** and run:

   ```bash
   curl -LO https://raw.githubusercontent.com/Jadocee/nightcoop-linux/main/nightcoop-install.sh
   chmod +x nightcoop-install.sh
   ./nightcoop-install.sh
   ```

3. Review the plan, confirm with `y`, then return to Game Mode and launch the game.

You do not need `sudo`, a password or a writable system partition. Do not use the pacman
package on SteamOS, because every SteamOS update replaces the system partition.

### CachyOS and Arch

Install the command as a package, then run it as your normal user. Do not use `sudo`,
because the mod goes into your own Steam library.

```bash
git clone https://github.com/Jadocee/nightcoop-linux.git
cd nightcoop-linux/packaging/arch
makepkg -si
nightcoop-install
```

Alternatively, without a package:

```bash
curl -LO https://raw.githubusercontent.com/Jadocee/nightcoop-linux/main/nightcoop-install.sh
chmod +x nightcoop-install.sh
./nightcoop-install.sh
```

The main menu then shows a **Co-op** entry ("Совместная игра" in Russian builds).

## What goes wrong under Proton, and what the script does about it

1. **Wine ignores RED4ext's loader.** NightCoop is a RED4ext plugin, and RED4ext starts
   through its own `bin/x64/winmm.dll`. By default Wine loads its built-in `winmm.dll`
   instead, even with RED4ext's copy in the game folder. The script fixes this in two
   places:
   - It adds `winmm = native,builtin` for `Cyberpunk2077.exe` to the prefix's registry.
     This works while Steam is open.
   - When Steam is closed, it also merges `WINEDLLOVERRIDES="winmm=n,b"` into the game's
     launch options, keeping every other option.

   If Cyber Engine Tweaks is installed, by you or with the mod set, its `version.dll`
   loader gets the same override.
2. **Steam installs an old C++ runtime.** On the game's first launch, Steam installs the
   Visual C++ 2019 runtime (14.29) into the prefix. RED4ext is built with MSVC 14.51.
   Loaded into the 2019 runtime, it fails with *"RED4ext (error 998) No access to memory
   location"* and an empty log. The script runs Microsoft's current installer (14.51)
   quietly inside the prefix. It uses the Proton build that last ran the game, through
   Proton's `runinprefix`, so Steam need not be running.
3. **Each RED4ext release supports one game patch.** NightCoop publishes one archive per
   patch with the matching RED4ext inside; for patch 2.5 that is RED4ext 1.31. The script
   reads the patch from `Cyberpunk2077.exe` and picks that archive. It installs the newest
   RED4ext the game supports from three candidates: the bundled copy, the release pinned
   in the script, and the installed copy. A working RED4ext is never replaced by an older
   one, but one that cannot run on the installed patch is replaced.

It also sets the game up for Proton:

- **Proton build** (`--proton`, see below): chosen in Steam's settings for the game.
- **`--launcher-skip`** is added to the launch options, so the game starts without CDPR's
  launcher window, which adds nothing under Proton. Use `--no-launcher-skip` to keep it.

Before it changes anything, the script does the following:

- It checks the archive's SHA-256 against nightcoop.net's release list, and the pinned
  RED4ext's against the script.
- It prints a plan and asks for confirmation.
- It copies every file it will replace into
  `~/.local/share/nightcoop-linux/backups/<date>/`, with a manifest of every file it adds.
  On the first install it copies your saves there too.

## Choosing the Proton build

`--proton auto`, the default, works as follows:

1. If you have already chosen a compatibility tool for Cyberpunk 2077 in Steam, it is
   kept.
2. On **CachyOS**, `proton-cachyos` is used when installed. The `proton-cachyos-slr`
   build is preferred, because it is built for the Steam Linux Runtime, the environment
   Valve's Proton runs in. The native build is the fallback.
3. Otherwise, **Proton Experimental** is used. It carries Valve's newest fixes, and Steam
   downloads it on the next launch if it is missing.

| `--proton` value | When to use it |
| --- | --- |
| `experimental` | Valve's tested base with the latest fixes. The safest choice on a Steam Deck. |
| `cachyos` | CachyOS's build: newer Wine, NTSYNC, FSR 4 upgrades. Usually the fastest on CachyOS. |
| `ge` | The newest GE-Proton in `compatibilitytools.d`, for its extra game fixes. |
| `keep` | Leave Steam's setting alone. On the Deck, this keeps Valve's per-game default. |
| a tool name | For example `proton_10` or `GE-Proton10-25`, exactly as Steam lists it. |

Whichever you choose, the runtime installed by the script is kept. When Steam moves the
prefix to another Proton version, it replaces only Wine's own files.

## Commands and options

| Command | Effect |
| --- | --- |
| `nightcoop-install` (or `./nightcoop-install.sh`) | Install, or update in place to the latest build for your game patch. |
| `… update` | The same as `install`. |
| `… check` | Report the installed versions and whether a newer NightCoop build exists, the Proton choice, the runtime, the overrides and the latest RED4ext and NightCoop logs. Changes nothing. |
| `… restore [DIR]` | Undo the most recent install (or the given backup). |
| `… uninstall` | Undo every install, newest first, leaving the game folder as it was. |

| Option | Effect |
| --- | --- |
| `--dry-run` | Detect, download and verify everything; change nothing. |
| `-y`, `--yes` | Do not ask for confirmation. |
| `--proton TOOL` | Choose the Proton build for the game (see above). |
| `--no-launcher-skip` | Do not add `--launcher-skip` to the launch options. |
| `--close-steam` | Close Steam to write its settings (launch options, Proton choice), then reopen it. Desktop Mode only. |
| `--force` | Reinstall every mod file, even those that already match the latest build. |
| `--backup-saves` | Copy the saves before an update too. By default only the first install copies them. |
| `--no-save-backup` | Skip the copy of the saves on the first install. The copy is skipped anyway when disk space is short. |
| `--nightcoop-zip FILE` | Use a NightCoop archive you downloaded yourself. |
| `--red4ext-zip FILE` | Use a RED4ext release archive, for example a newer one than the script pins. |
| `--vcredist FILE` | Use a `VC_redist.x64.exe` you downloaded yourself. |
| `--steam-root DIR` | Use this Steam installation instead of detecting one. |
| `--with-flight` | Also install Let There Be Flight and the mods it needs (see below). Later runs keep them up to date. |
| `--without-flight` | Remove Let There Be Flight again. The mods it needed stay, because other mods use them too. |
| `--with-mods` | Also install the mod set: Virtual Atelier with two stores, Quick Stash, No Intro Videos and the frameworks they need (see below). Later runs keep it up to date. |
| `--without-mods` | Remove the mod set's mods again. The frameworks stay. |
| `--mods-from DIR` | Look for the Nexus Mods downloads in DIR instead of your Downloads folder. |

When Steam is running, its two settings are not written, but the registry override alone
lets the mod load. The script then prints the launch options and the Proton choice for you
to set under Properties. Alternatively, rerun it with Steam closed or with `--close-steam`.

## Other mods

NightCoop needs only RED4ext, which comes with it; it does not need Cyber Engine Tweaks.
The script leaves other mods alone: it writes only RED4ext, NightCoop's own folders and
the sets below, and `uninstall` keeps everything else. Mods built for NightCoop's SDK work
in co-op with partners who have them too. Other mods are not synced, so it is safest for
everyone in a session to use the same ones.

Add either optional set once; later runs keep it up to date:

```bash
nightcoop-install --with-flight --with-mods
```

### Let There Be Flight (`--with-flight`)

**Let There Be Flight** (flying cars, by Jack Humbert) is the one mod NightCoop supports
out of the box. NightCoop's archive already holds its co-op port, which the script
installs. The port shows your flight on your partners' screens, and does nothing until Let
There Be Flight is installed.

| Mod | Game 2.5 | Why it is needed |
| --- | --- | --- |
| Let There Be Flight | 0.3.20 | The flight itself |
| ArchiveXL | 1.28.6 | Loads its game assets |
| TweakXL | 1.12.0 | Loads its game data changes |
| Input Loader | 0.2.6 | Adds its key bindings |
| redscript | 0.5.32 | Compiles its scripts, and NightCoop's port |

- **Every player** who wants to see the flight properly needs Let There Be Flight. NightCoop
  names the partners who lack it. Without it, a partner sees your car flying without
  wheels.
- **Settings:** the key bindings are in
  `red4ext/plugins/let_there_be_flight/inputs.xml`. The optional Mod Settings menu is not
  installed, for the reason given below.

### The mod set (`--with-mods`)

| Mod | Source | What it does |
| --- | --- | --- |
| Virtual Atelier, the **Basic** file | Nexus Mods, [2987](https://www.nexusmods.com/cyberpunk2077/mods/2987?tab=files) | Online stores for clothing and items, opened from in-game computers |
| A.G.I.S. (All Game Items Store) | Nexus Mods, [10909](https://www.nexusmods.com/cyberpunk2077/mods/10909?tab=files) | A Virtual Atelier store selling every item in the game |
| Night City Marketplace | Nexus Mods, [4433](https://www.nexusmods.com/cyberpunk2077/mods/4433?tab=files) | Lore-friendly Virtual Atelier stores of the game's own items |
| Quick Stash | Nexus Mods, [30016](https://www.nexusmods.com/cyberpunk2077/mods/30016?tab=files) | Moves your inventory to V's stash or your car in one go (not equipped or quest items) |
| No Intro Videos | Nexus Mods, [533](https://www.nexusmods.com/cyberpunk2077/mods/533?tab=files) | Skips the logo videos at start-up |
| Cyber Engine Tweaks 1.38.1 | GitHub, automatic | Runs Lua mods such as Quick Stash |
| Codeware 1.21.2 | GitHub, automatic | The library Virtual Atelier is built on |
| TweakXL 1.12.0, ArchiveXL 1.28.6 | GitHub, automatic | Load game-data changes and new assets, for the many item mods that use them |
| redscript 0.5.32 | GitHub, automatic | Compiles the script mods, NightCoop's included |

Nexus Mods does not let scripts download files (a browser check, and an API that needs
each user's key), so you download those five yourself:

1. Run `nightcoop-install --with-mods`. It installs the frameworks and prints the Nexus
   page of each mod you have not downloaded yet.
2. Sign in to Nexus Mods (a free account is enough). On each page's Files tab, choose
   **Manual download**; for Virtual Atelier, take the **Basic** file. Keep the name Nexus
   gives the file: it holds the mod's ID, which is how the script recognises it.
3. Run the script again. It finds the files in your Downloads folder (or the folder given
   with `--mods-from`) and installs them. It keeps a copy in
   `~/.cache/nightcoop-linux/mods`, so you may delete the downloads. To update one of
   these mods later, download its newer file and run the script again.

Each archive's game folders (`archive`, `bin`, `engine`, `mods`, `r6`, `red4ext`) are
installed, without read-me files or installer data, also when an archive wraps them in a
folder of its own. Zip archives need nothing extra; 7z and RAR archives are unpacked with
`bsdtar` from libarchive. A mod whose requirement is missing is left out with a warning;
for example, a store without Virtual Atelier would stop redscript from compiling every
script, NightCoop's included.

**How the set stays compatible with NightCoop:**

- **Virtual Atelier's Basic file only.** The Full file needs Mod Settings, which replaces
  the pause, death and main menus, where NightCoop's co-op entry lives; NightCoop's own
  guide lists the overlap. The script never installs a Virtual Atelier file with "Full" in
  its name.
- **Stores of the game's own items.** What you buy from them is an ordinary game item, so
  partners without the stores see it too. Stores of modded outfits would need every player
  to install the same outfit mods, so none are included.
- **Browser Extension is left out.** It adds Virtual Atelier to the in-game browser, but
  players report it broken since patch 2.3, and no update for 2.5 was found. Virtual
  Atelier's stores open from in-game computers without it.
- **Quick Stash in co-op:** everyone in a session plays in the host's world, so the stash a
  guest opens there is not the guest's own. Move items in your own game, or as the host;
  the script reminds you of this.
- **No Intro Videos** replaces the start-up videos rather than hooking the game, so it
  does not overlap NightCoop's own intro skip. Its page lists patch 2.3 and later, and
  players report it working on 2.5.
- **Cyber Engine Tweaks mods** work with NightCoop. One that replaces a game function
  without calling the original can break parts of co-op; NightCoop names such conflicts
  in its log (`red4ext/logs/nightcoop-*.log`). On its first start, Cyber Engine Tweaks
  asks which key opens its overlay.

### Both sets

- **Matched to your game patch:** the pairings for the GitHub releases come from each
  project's README and release notes, and from the game version their DLLs are built for.
  Those archives are checked against SHA-256 values pinned in the script. On a game patch
  the script does not know yet, what is installed is left as it is.
- **Shared frameworks** (redscript, ArchiveXL, TweakXL) are installed once.
- **Copies you installed yourself:** a framework copy that is newer and built for the same
  patch is kept. Any other copy is replaced, and backed up like every file the script
  replaces. redscript has no readable version, so it is always the paired build.
- **Removing them:** `--without-flight` removes Let There Be Flight, and `--without-mods`
  removes the five Nexus mods, Quick Stash from inside Cyber Engine Tweaks' folder too.
  The frameworks stay, because many other mods need them. `uninstall` removes everything
  the script installed and puts back the game files it replaced: the game's script
  compiler, which redscript replaces, and the input files Input Loader changes.
- **`check`** lists each set with its versions, and any mod still to download.

## Updating and undoing

- **New NightCoop build:** run the script again (`update` is another name for
  `install`). It asks nightcoop.net for the latest build for your game patch and
  compares it with the game folder, file by file:
  - When everything matches, it says so and changes nothing.
  - Otherwise it backs up and replaces only the files that differ. As NightCoop's own
    guide asks, files of the old build that the new one no longer has are removed from
    `red4ext/plugins/NightCoop`, while your `servers.txt`, `hub.txt` and `logs` stay.
  - The saves are not copied on an update; add `--backup-saves` for a fresh copy.
    `--force` reinstalls every file.
  - A NightCoop you installed by hand is recognised when its files match the latest
    build, and recorded instead of replaced.
  - The archive is kept in `~/.cache/nightcoop-linux`, so a rerun does not download it
    again.

  `check` shows the installed build and whether the site has a newer one. Everyone in a
  session needs a build with the same protocol number, so when one player updates, the
  others run the script again too.
- **Undo the last update:** run `restore`.
- **Remove NightCoop completely:** run `uninstall`. This restores the game folder
  exactly, keeping other RED4ext plugins you installed yourself, and puts back the
  prefix runtime and registry. Steam's launch options and Proton choice are left as they
  are; change them under Properties if you wish. Saves are never touched.
- Backups made by the earlier Bazzite script (`~/nightcoop-backup-*`) can still be
  restored.

## Troubleshooting

Start with `check`.

- **No Co-op entry and an empty RED4ext log** (`red4ext/logs/red4ext-*.log`). RED4ext
  stopped before it could write, which is the runtime problem. Run the script again; if
  the runtime still shows as too old, `check` prints a protontricks command for your
  system.
- **"To use this version of RED4ext, ensure your game is updated to patch …"** in the
  RED4ext log. The RED4ext does not match the game patch. Run the script again; it picks
  the matching one.
- **After a game patch.** Rerun the script; it picks the NightCoop build and RED4ext for
  the new patch. If the patch is newer than the script knows, it uses the RED4ext that
  NightCoop bundles, and leaves the mod sets as they are.
- **A mod of the set is not installed.** `check` lists it as missing. Download it from the
  page the script prints, keeping Nexus's file name, and run the script again.
- **Logs for a bug report.** NightCoop writes `red4ext/logs/nightcoop-*.log`, and crash
  and hang logs go to `red4ext/plugins/NightCoop/logs`. For Proton's own log, add
  `PROTON_LOG=1` to the launch options; it is written to `~/steam-1091500.log`.
- **Game library on an NTFS or exFAT drive.** This is common on dual-boot systems, and
  Proton prefixes misbehave there. The script warns about it; move the game to an ext4
  or btrfs library.
- **`vm.max_map_count` warning.** Cyberpunk 2077 needs at least 1048576. SteamOS,
  CachyOS and current Arch set this by default; `check` prints the fix if yours does not.
- **A deleted prefix** (`steamapps/compatdata/1091500`, sometimes removed to fix other
  problems) is recreated on the next launch with Steam's 2019 runtime. Run the script
  again.
- **"Verify integrity of game files"** does not remove the mod.

## How this was verified

The installer was run against real components in Arch Linux, CachyOS and SteamOS 3.8
roots built from each distribution's own signed package repositories:

- `proton-cachyos-native` 11.0 from CachyOS's repository;
- the live NightCoop 0.2.0 archives and release list;
- RED4ext 1.31;
- Microsoft's VC++ 2019, 2022 and v14 installers;
- the GitHub releases of both mod sets.

The game itself cannot run there, so a stand-in `Cyberpunk2077.exe` was used. It carries
the real game's version data and imports, enough for RED4ext to start as it does in the
game.

| Situation | Result under Proton |
| --- | --- |
| Mod files only, no override | Wine loads its own `winmm.dll`; RED4ext never starts |
| Registry override (Steam open) or launch options | RED4ext's loader runs and RED4ext starts |
| Steam's first-launch 2019 runtime (14.29) | "RED4ext (error 998)", empty log: the reported symptom |
| After the script installs 14.51 (or 14.44) | RED4ext starts |
| VS 2019 installer run again after the fix | Exits with "newer version installed"; 14.51 stays |

The full install ran online as a normal user on CachyOS, for game 2.5, with Let There Be
Flight. A launch through Proton afterwards started RED4ext both with and without the
launch options. Adding the mod set then installed its frameworks, gave Cyber Engine
Tweaks' loader its override and listed the Nexus downloads. The test suite passes on all
three systems.

**Not covered:**

- the real game on real hardware, with a GPU and the main menu;
- the Nexus Mods files, which scripts cannot download. The tests use archives laid out
  like them, and the mods' support for patch 2.5 comes from their pages and players'
  reports.

If you try it, a report of `check` output with the result is welcome.

## Packaging

`packaging/arch/PKGBUILD` builds `nightcoop-linux-git`, which installs the
`nightcoop-install` command and runs the test suite in `check()`. `.SRCINFO` is kept next
to it for the AUR; regenerate it with `makepkg --printsrcinfo > .SRCINFO` after changing
the PKGBUILD.

## Development

`tests/run-tests.sh` runs the installer end to end against a synthetic Steam
installation. It covers:

- SD-card and Flatpak libraries;
- `proton-cachyos` and the `--proton` choices;
- Steam open while installing;
- game patch 2.5, an older patch (refused) and a newer one the tables do not know;
- Cyber Engine Tweaks;
- a hand-copied old NightCoop build;
- updates in place: nothing changed when current, only differing files replaced, saves
  copied once, `--force` and `--backup-saves`;
- the flight set:
  - paired with the game patch, and left as it is on an unknown patch;
  - a newer copy installed by hand kept;
  - `--without-flight` removing only Let There Be Flight;
  - an archive with the wrong SHA-256 refused;
- the mod set:
  - the frameworks from GitHub, Cyber Engine Tweaks' override from the first run;
  - the Nexus files found in the Downloads folder, a localised one too, and installed
    from the script's own copy once they are deleted;
  - Virtual Atelier's Basic file preferred and its Full file never installed;
  - a missing requirement leaving a mod out, and missing downloads listed;
  - an archive wrapped in a folder, and one without game folders refused;
  - `--without-mods` removing only the mods, Quick Stash from inside Cyber Engine Tweaks'
    folder too, while the flight set keeps the frameworks it shares;
- install, update, restore and uninstall back to a byte-identical game folder.

`tests/mkfixtures.py` generates the PE files, archives (shaped like nightcoop.net's, the
mods' GitHub releases and Nexus Mods' downloads) and a stand-in Proton, so the suite
needs neither Steam, Wine nor network access.

CI runs the suite in Arch Linux, CachyOS and SteamOS (holo) containers and on Ubuntu. It
also builds the PKGBUILD with `makepkg`, checks it with `namcap`, and runs shellcheck.

[`sandbox/`](sandbox) recreates the verification environments as Docker Compose services:

- the test suite on Arch, CachyOS and SteamOS 3.8 built from Valve's repositories;
- the PKGBUILD;
- the real-Proton checks. These are the verification matrix above, and a full online
  install and launch for patch 2.5 with `proton-cachyos`, the stand-in game and both mod
  sets.

Run one with `docker compose -f sandbox/compose.yaml run --rm --build experiments`. A
weekly CI run repeats them all to catch new Proton, RED4ext, NightCoop or SteamOS releases
that break an assumption.

`nightcoop-install __py <command> …` calls the embedded helper directly, which is useful
when debugging (for example, `__py gamever …/Cyberpunk2077.exe`).

## Licence

This repository is released under the [MIT Licence](LICENSE). NightCoop, RED4ext and
Microsoft's Visual C++ runtime are not part of it: the script downloads them from their
publishers when it runs, and their own licences apply.
