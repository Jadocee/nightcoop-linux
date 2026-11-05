# NightCoop on Arch Linux and SteamOS

[NightCoop](https://nightcoop.net/) is an unofficial co-op mod for Cyberpunk 2077. Its
site documents Windows only. Under Proton the mod runs well, but three things stop it
from loading out of the box. `nightcoop-install.sh` fixes all three and installs the mod
on SteamOS (Steam Deck), CachyOS and other Arch-based systems.

## Supported systems

| System | Notes |
| --- | --- |
| **SteamOS 3** (Steam Deck LCD and OLED, other SteamOS devices) | Run from Desktop Mode. Games on an SD card are found automatically. Nothing is installed into the read-only system, and Steam may stay open. |
| **CachyOS** | Works with Proton Experimental, Valve's numbered Proton releases and the `proton-cachyos` packages. Existing launch options such as `game-performance %command%` are kept. |
| **Arch Linux** and derivatives (EndeavourOS, Manjaro, Garuda, …) | Steam from `[multilib]`. A minimal install may need `sudo pacman -S --needed python curl`. |
| **Flatpak Steam** (any distribution) | Detected automatically. |
| Bazzite and other distributions | Same code path; the earlier Bazzite-only installer is superseded by this script. |

## Quick start

First, on any system: **launch Cyberpunk 2077 once through Steam, wait for the main
menu, and quit.** This creates the Proton prefix that the script works on.

### Steam Deck and SteamOS

1. Switch to Desktop Mode: press the Steam button, then select Power > Switch to Desktop.
2. Open **Konsole** and run:

   ```bash
   curl -LO https://raw.githubusercontent.com/Jadocee/nightcoop-linux/main/nightcoop-install.sh
   chmod +x nightcoop-install.sh
   ./nightcoop-install.sh
   ```

3. Review the plan, confirm with `y`, then return to Game Mode and launch the game.

You do not need `sudo`, a password or a writable system partition.

### CachyOS and Arch

On CachyOS, Proton Experimental and `proton-cachyos` are both fine. Pick one under
Properties > Compatibility before the first launch. Then:

```bash
curl -LO https://raw.githubusercontent.com/Jadocee/nightcoop-linux/main/nightcoop-install.sh
chmod +x nightcoop-install.sh
./nightcoop-install.sh
```

The main menu should then show a new **Co-op** entry ("Совместная игра" in Russian builds).

## What goes wrong under Proton, and what the script does about it

1. **Wine ignores RED4ext's loader.** NightCoop is a RED4ext plugin, and RED4ext loads
   through its own `winmm.dll`. By default Wine uses its built-in copy instead. The script
   adds the per-game override `winmm = native,builtin` to the prefix's registry. This
   works while Steam is open, which matters on SteamOS, where Steam practically always
   runs. When Steam is closed, it also merges `WINEDLLOVERRIDES="winmm=n,b"` into the
   game's launch options and keeps whatever was there.
2. **The prefix's C++ runtime is too old.** Proton ships an old Microsoft Visual C++
   runtime. RED4ext 1.31 is built with MSVC 14.51, and on an older runtime it crashes with
   *"RED4ext (error 998) No access to memory location"*. Anything older than 14.40
   always fails. The script reads the required version from the DLLs themselves. It then
   runs the newest installer it can find inside the game's prefix, using the same Proton
   build the game uses. The installer comes from Steam's `Steamworks Shared` copy or from
   Microsoft, whichever is newer.
3. **The bundled RED4ext may be too old.** Some NightCoop archives ship a RED4ext that
   does not work on the current game patch. The script installs the newest of three:
   the copy in the NightCoop archive, the release pinned in the script (checksum-verified),
   and the copy already in the game folder. It never downgrades.

Before it changes anything, the script does the following:

- It picks the NightCoop build that matches your game version from nightcoop.net and
  checks its SHA-256 against the site's release list.
- It prints a plan and asks for confirmation.
- It copies your saves and every file it will replace into
  `~/.local/share/nightcoop-linux/backups/<date>/`, along with a manifest of every file
  it adds.

## Commands and options

| Command | Effect |
| --- | --- |
| `./nightcoop-install.sh` | Install, or update to the latest build for your game version. |
| `./nightcoop-install.sh check` | Report versions, overrides, runtime and the latest RED4ext log. Changes nothing. |
| `./nightcoop-install.sh restore [DIR]` | Undo the most recent install (or the given backup). |
| `./nightcoop-install.sh uninstall` | Undo every install, newest first, leaving the game folder as it was. |

| Option | Effect |
| --- | --- |
| `--dry-run` | Detect, download and verify everything; change nothing. |
| `-y`, `--yes` | Do not ask for confirmation. |
| `--close-steam` | Close Steam to write the launch options, then reopen it (Desktop Mode only). |
| `--no-save-backup` | Skip the copy of the saves. The copy is skipped anyway when disk space is short. |
| `--nightcoop-zip FILE` | Use a NightCoop archive you downloaded yourself. |
| `--red4ext-zip FILE` | Use a RED4ext release archive, for example a newer one than the script pins. |
| `--vcredist FILE` | Use a `VC_redist.x64.exe` you downloaded yourself. |
| `--steam-root DIR` | Use this Steam installation instead of detecting one. |

## Updating and undoing

- **New NightCoop build:** run the script again. It backs up the current build, installs
  the new one and removes files the old build had that the new one no longer ships.
  Everyone in a session needs a build with the same protocol number.
- **Undo the last update:** run `./nightcoop-install.sh restore`.
- **Remove NightCoop completely:** run `./nightcoop-install.sh uninstall`. This restores
  the game folder exactly, keeping other RED4ext plugins you installed yourself, and puts
  back the prefix runtime and registry. Launch options are left alone; clear them under
  Properties > General if you wish. Saves are never touched.
- Backups made by the earlier Bazzite script (`~/nightcoop-backup-*`) can still be
  restored.

## Troubleshooting

Start with `./nightcoop-install.sh check`.

- **No Co-op entry and an empty RED4ext log.** RED4ext crashed before it could write
  anything: this is the runtime problem. Run the installer again. If the runtime still
  shows as too old, `check` prints a protontricks command for your system. On SteamOS,
  install Protontricks from Discover; on Arch, use the AUR or Flathub.
- **It worked, then stopped after a Proton update.** A major Proton upgrade can rebuild
  the prefix and bring back the old runtime. Run the script again; it skips what is
  already in place.
- **After a game patch.** The game may need a newer NightCoop or RED4ext. Rerunning
  picks up the newest NightCoop build for your game version. For RED4ext, pass a newer
  release with `--red4ext-zip`, or update `RED4EXT_VER`, `RED4EXT_URL` and `RED4EXT_SHA`
  at the top of the script.
- **Game library on an NTFS or exFAT drive.** This is common on dual-boot CachyOS
  systems. Proton prefixes misbehave on these file systems, and the script warns about
  it. Move the game to an ext4 or btrfs library.
- **`vm.max_map_count` warning.** Cyberpunk 2077 needs at least 1048576. SteamOS and
  current Arch set this by default; `check` prints the fix if yours does not.
- **"Verify integrity of game files"** does not remove the mod.

## Development

`tests/run-tests.sh` runs the installer end to end against a synthetic Steam installation:

- the game on an SD-card library;
- Flatpak Steam;
- `proton-cachyos` chosen in Steam's settings;
- Steam open while installing;
- a newer RED4ext already installed;
- install, update, restore and uninstall back to a byte-identical game folder.

The PE files, archives and a stand-in Proton are generated by `tests/mkfixtures.py`, so
the suite needs neither Steam, Wine nor network access. CI runs it in an Arch Linux
container and runs shellcheck over the scripts.

`./nightcoop-install.sh __py <command> …` calls the embedded helper directly, which is
useful when debugging (for example, `__py pever FILE product`).
