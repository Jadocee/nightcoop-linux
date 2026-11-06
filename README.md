# NightCoop on Arch Linux and SteamOS

[NightCoop](https://nightcoop.net/) is an unofficial co-op mod for Cyberpunk 2077, and
its site supports Windows only. The mod runs well under Proton, but three problems stop
it from loading out of the box. `nightcoop-install.sh` fixes all three, installs the mod
and sets up Proton for the game on SteamOS (Steam Deck), CachyOS and other Arch-based
systems.

## Supported systems

| System | Notes |
| --- | --- |
| **SteamOS 3** (Steam Deck LCD and OLED, other SteamOS devices) | Run from Desktop Mode. Games on an SD card are found. Nothing is installed into the read-only system, and Steam may stay open. |
| **CachyOS** | Uses `proton-cachyos` when it is installed, otherwise Proton Experimental. Keeps launch options such as `game-performance %command%`. Installable as a pacman package. |
| **Arch Linux** and derivatives (EndeavourOS, Manjaro, Garuda, …) | Steam from `[multilib]`. Installable as a pacman package. |
| **Flatpak Steam** (any distribution) | Detected automatically. |
| Bazzite and other distributions | Same code path. |

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

   If Cyber Engine Tweaks is installed, its `version.dll` loader gets the same override.
2. **Steam installs an old C++ runtime.** On the game's first launch, Steam installs the
   Visual C++ 2019 runtime (14.29) into the prefix. RED4ext is built with MSVC 14.51.
   Loaded into the 2019 runtime, it fails with *"RED4ext (error 998) No access to memory
   location"* and an empty log. The script runs Microsoft's current installer (14.51)
   quietly inside the prefix. It uses the Proton build that last ran the game, through
   Proton's `runinprefix`, so Steam need not be running.
3. **Each RED4ext release supports one game patch.** RED4ext 1.31 refuses anything older
   than patch 2.5, and 1.30 is the release for 2.31. NightCoop publishes one archive per
   patch with the matching RED4ext inside. The script reads the patch from
   `Cyberpunk2077.exe` and picks that archive. It installs the newest RED4ext the game
   supports from three candidates: the bundled copy, the release pinned in the script,
   and the installed copy. A working RED4ext is never replaced by an older one, but one
   that cannot run on the installed patch is replaced.

It also sets the game up for Proton:

- **Proton build** (`--proton`, see below): chosen in Steam's settings for the game.
- **`--launcher-skip`** is added to the launch options, so the game starts without CDPR's
  launcher window, which adds nothing under Proton. Use `--no-launcher-skip` to keep it.

Before it changes anything, the script does the following:

- It checks the archive's SHA-256 against nightcoop.net's release list, and the pinned
  RED4ext's against the script.
- It prints a plan and asks for confirmation.
- It copies your saves and every file it will replace into
  `~/.local/share/nightcoop-linux/backups/<date>/`, with a manifest of every file it adds.

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
| `nightcoop-install` (or `./nightcoop-install.sh`) | Install, or update to the latest build for your game patch. |
| `… check` | Report the installed versions, the Proton choice, the runtime, the overrides and the latest RED4ext and NightCoop logs. Changes nothing. |
| `… restore [DIR]` | Undo the most recent install (or the given backup). |
| `… uninstall` | Undo every install, newest first, leaving the game folder as it was. |

| Option | Effect |
| --- | --- |
| `--dry-run` | Detect, download and verify everything; change nothing. |
| `-y`, `--yes` | Do not ask for confirmation. |
| `--proton TOOL` | Choose the Proton build for the game (see above). |
| `--no-launcher-skip` | Do not add `--launcher-skip` to the launch options. |
| `--close-steam` | Close Steam to write its settings (launch options, Proton choice), then reopen it. Desktop Mode only. |
| `--no-save-backup` | Skip the copy of the saves. The copy is skipped anyway when disk space is short. |
| `--nightcoop-zip FILE` | Use a NightCoop archive you downloaded yourself. |
| `--red4ext-zip FILE` | Use a RED4ext release archive, for example a newer one than the script pins. |
| `--vcredist FILE` | Use a `VC_redist.x64.exe` you downloaded yourself. |
| `--steam-root DIR` | Use this Steam installation instead of detecting one. |

When Steam is running, its two settings are not written, but the registry override alone
lets the mod load. The script then prints the launch options and the Proton choice for you
to set under Properties. Alternatively, rerun it with Steam closed or with `--close-steam`.

## Updating and undoing

- **New NightCoop build:** run the script again. As NightCoop's own guide asks, it
  replaces the `red4ext/plugins/NightCoop` folder as a whole, keeping your
  `servers.txt`, `hub.txt` and `logs`. Everyone in a session needs a build with the same
  protocol number.
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
  NightCoop bundles.
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
- RED4ext 1.30 and 1.31;
- Microsoft's VC++ 2019, 2022 and v14 installers.

The game itself cannot run there, so a stand-in `Cyberpunk2077.exe` was used. It carries
the real game's version data and imports, enough for RED4ext to start as it does in the
game.

| Situation | Result under Proton |
| --- | --- |
| Mod files only, no override | Wine loads its own `winmm.dll`; RED4ext never starts |
| Registry override (Steam open) or launch options | RED4ext's loader runs and RED4ext starts |
| Steam's first-launch 2019 runtime (14.29) | "RED4ext (error 998)", empty log: the reported symptom |
| After the script installs 14.51 (or 14.44) | RED4ext starts |
| RED4ext 1.31 on game 2.31 | Refused by RED4ext; the script now installs 1.30 there |
| VS 2019 installer run again after the fix | Exits with "newer version installed"; 14.51 stays |

The full install ran online as a normal user on CachyOS, for game 2.5 and game 2.31. A
launch through Proton afterwards started RED4ext both with and without the launch
options. The test suite passes on all three systems.

**Not covered:** the real game on real hardware, with a GPU and the main menu. If you try
it, a report of `check` output with the result is welcome.

## Packaging

`packaging/arch/PKGBUILD` builds `nightcoop-linux-git`, which installs the
`nightcoop-install` command and runs the test suite in `check()`. `.SRCINFO` is kept next
to it for the AUR. The repository has no licence yet, so the PKGBUILD says
`LicenseRef-unknown`; choose a licence before publishing the package.

## Development

`tests/run-tests.sh` runs the installer end to end against a synthetic Steam
installation. It covers:

- SD-card and Flatpak libraries;
- `proton-cachyos` and the `--proton` choices;
- Steam open while installing;
- game patches 2.5 and 2.31;
- Cyber Engine Tweaks;
- a hand-copied old NightCoop build;
- install, update, restore and uninstall back to a byte-identical game folder.

`tests/mkfixtures.py` generates the PE files, archives (shaped like nightcoop.net's) and
a stand-in Proton, so the suite needs neither Steam, Wine nor network access.

CI runs the suite in Arch Linux, CachyOS and SteamOS (holo) containers and on Ubuntu. It
also builds the PKGBUILD with `makepkg`, checks it with `namcap`, and runs shellcheck.

`nightcoop-install __py <command> …` calls the embedded helper directly, which is useful
when debugging (for example, `__py gamever …/Cyberpunk2077.exe`).
