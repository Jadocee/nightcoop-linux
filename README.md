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
| **CachyOS** | Uses `proton-cachyos` when it is installed, otherwise Proton Experimental. Starts the game with `game-performance`, CachyOS's performance power profile. Installable as a pacman package. |
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
   - When Steam is closed, it also writes the game's launch options, starting with
     `WINEDLLOVERRIDES="winmm=n,b"` (see [Launch options](#launch-options)).

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
- **Launch options** (see [Launch options](#launch-options)): besides the DLL overrides,
  `--launcher-skip` and, where it can run, `game-performance`. MangoHud is optional.

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

## Launch options

Steam's launch options take the form `[variables] [wrappers] %command% [game arguments]`.
The script writes the whole line from the parts below and nothing else: other variables,
wrappers (`gamemoderun`, `prime-run`, `gamescope … --`) and game arguments are replaced.
The earlier line is kept in the run's backup folder (`launch-options.txt`), and the script
says so; add anything you need back under Properties after the run.

| Part | Added | What it does |
| --- | --- | --- |
| `WINEDLLOVERRIDES="winmm=n,b"` | Always. It becomes `winmm,version` once Cyber Engine Tweaks is installed. | Required: without it, Wine ignores RED4ext's loader (and Cyber Engine Tweaks'). |
| `game-performance` | When it can run: native Steam, CachyOS's `game-performance`, and `powerprofilesctl` (power-profiles-daemon). A newer `game-performance` that supports TLP's `tlpctl` can use that instead; cachyos-settings 1.4.1 does not. | Runs the game in the performance power profile, and restores the previous profile when the game exits. It goes last, right before `%command%`. |
| `MANGOHUD=1` | With `--mangohud`, or when the line had MangoHud already; only where MangoHud is installed. | Shows MangoHud's overlay in the game. |
| `--launcher-skip` | Unless `--no-launcher-skip` is given. | Starts the game without CDPR's launcher window, which adds nothing under Proton. |
| `-modded` | Only with `--redmod`, which is remembered; `--no-redmod` takes it out. | Loads REDmod mods once they are deployed (see below). It goes after the other game arguments. |

Nothing else is required: no mod in the sets is a REDmod, and Audioware, Mod Settings and
the other frameworks need no variables.

- **game-performance** stops the game from starting where it cannot run:
  - under Flatpak Steam, which starts the game inside its sandbox, without the host's
    programs;
  - without `powerprofilesctl` (or `tlpctl`, for a release that supports it), when it exits
    with an error.

  In those cases the script takes it out of the launch options, and says why.
  `--no-game-performance` leaves it out on later runs too; `--game-performance` undoes that.
- **MangoHud** is optional.
  - `--mangohud` writes `MANGOHUD=1` rather than the `mangohud` wrapper. Under Proton the
    game draws with Vulkan, and for Vulkan that variable is what turns MangoHud's layer on.
    The wrapper sets it too, along with an OpenGL hook the game does not use. Unlike the
    wrapper, the variable cannot stop the game from starting if MangoHud is removed later.
  - It is not added on SteamOS, whose own performance overlay (Quick Access menu >
    Performance) shows the same.
  - Once in the line, it stays on later runs while MangoHud can run there.
  - Flatpak Steam needs the `org.freedesktop.Platform.VulkanLayer.MangoHud` extension for
    Steam's runtime; the script names the one to install.
  - `--no-mangohud` takes MangoHud out again, including the `mangohud` wrapper.
- **REDmod** is CDPR's own mod format: mods in `mods/<name>/`, each with an `info.json`. The
  game loads them only when started with `-modded`, after a deploy that compiles them into
  `r6/cache/modded`. No mod in the sets is one, so the script leaves `-modded` out unless
  you run it with `--redmod`, which it remembers.
  - A `-modded` that was in the line before goes with the rest of it. The script says so
    and names `--redmod`, as it does when REDmod mods are in `mods/` without `-modded`;
    `check` shows them.
  - Deploying needs the free REDmod DLC (the game's Properties > DLC in Steam). CDPR's
    launcher deploys when its mods setting is on, but `--launcher-skip` skips the launcher:
    after adding or changing a REDmod mod, run the script once with `--no-launcher-skip`,
    or run `tools/redmod/bin/redMod.exe deploy` in the game's Proton prefix. The script
    does not deploy.
  - redscript compiles its scripts on top of the deployed ones. NightCoop cannot check
    REDmod script mods (`mods/<name>/scripts/`) for overlaps with what co-op relies on,
    since they replace whole game script files, so try each one in co-op first.

On CachyOS with Cyber Engine Tweaks installed, a run with `--mangohud` gives:

```
WINEDLLOVERRIDES="winmm,version=n,b" MANGOHUD=1 game-performance %command% --launcher-skip
```

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
| `--no-game-performance` | Do not start the game with `game-performance`, and take it out of the launch options. Remembered in `~/.local/share/nightcoop-linux/settings.tsv`; `--game-performance` undoes it. |
| `--mangohud` | Show MangoHud's overlay in the game (`MANGOHUD=1` in the launch options). Not on SteamOS. `--no-mangohud` takes it out. |
| `--redmod` | Start the game with `-modded`, which loads REDmod mods. Remembered; `--no-redmod` takes it out. |
| `--close-steam` | Close Steam to write its settings (launch options, Proton choice), then reopen it. Desktop Mode only. |
| `--force` | Reinstall every mod file, even those that already match the latest build. |
| `--backup-saves` | Copy the saves before an update too. By default only the first install copies them. |
| `--no-save-backup` | Skip the copy of the saves on the first install. The copy is skipped anyway when disk space is short. |
| `--nightcoop-zip FILE` | Use a NightCoop archive you downloaded yourself. |
| `--red4ext-zip FILE` | Use a RED4ext release archive, for example a newer one than the script pins. |
| `--vcredist FILE` | Use a `VC_redist.x64.exe` you downloaded yourself. |
| `--steam-root DIR` | Use this Steam installation instead of detecting one. |
| `--with-flight` | Also install Let There Be Flight and the mods it needs, without the rest of the mod set, which includes it (see below). Later runs keep them up to date. |
| `--without-flight` | Remove Let There Be Flight again, unless the mod set is on. The mods it needed stay, because other mods use them too. |
| `--with-mods` | Also install the mod set: Virtual Atelier with clothing and item stores and their outfits (Zenitex, The RVC00N Dumpster, Nola Dreamer, Street Ninja), hairstyles, Let There Be Flight, Virtual Car Dealer with car and bike packs, Drive an Aerial Vehicle, Vehicle Customizer, Curbside, Cyber Drift, Impact FX, Immersive Audio Distance, Immersive First Person, Katana Pack 2, Quick Stash, No Intro Videos, and the frameworks they need (see below). Later runs keep it up to date. |
| `--without-mods` | Remove the mod set's mods again. The frameworks stay. |
| `--with-equipment-ex` | Also install Equipment-EX, to wear layered outfits, and with `--with-mods` raem's jewellery made for its slots (see below). Every partner in a session needs it too. |
| `--without-equipment-ex` | Remove Equipment-EX again. |
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

Add an optional set once; later runs keep it up to date. The mod set includes Let There Be
Flight:

```bash
nightcoop-install --with-mods
```

### Let There Be Flight (in the mod set, or `--with-flight` alone)

**Let There Be Flight** (flying cars, by Jack Humbert) is the one mod NightCoop supports
out of the box. NightCoop's archive already holds its co-op port, which the script
installs. The port shows your flight on your partners' screens, and does nothing until Let
There Be Flight is installed. The mod set installs it with the rest; `--with-flight`
installs it on its own, with only what it needs.

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
  `red4ext/plugins/let_there_be_flight/inputs.xml`. Its optional Mod Settings menu comes
  with the mod set, which installs Mod Settings for Virtual Atelier (see below why that
  is safe); `--with-flight` alone does not install Mod Settings.

### The mod set (`--with-mods`)

The set includes Let There Be Flight and what it needs (above), and the mods below. The
Nexus numbers link to each mod's files; "for game 2.5" is the oldest release known to work
with the patch.

**Stores and outfits** (Virtual Atelier, on in-game computers)

| Mod | Nexus | For game 2.5 | What it is |
| --- | --- | --- | --- |
| Virtual Atelier | [2987](https://www.nexusmods.com/cyberpunk2077/mods/2987?tab=files) | 1.6.4 or newer | The online stores themselves |
| A.G.I.S. (All Game Items Store), its main file PUBLICNET | [10909](https://www.nexusmods.com/cyberpunk2077/mods/10909?tab=files) | 1.2.1 or newer | Every item in the game |
| Night City Marketplace | [4433](https://www.nexusmods.com/cyberpunk2077/mods/4433?tab=files) | 2.3.0 or newer | Lore-friendly stores of the game's own items |
| All Vanilla Clothes Atelier Store | [5544](https://www.nexusmods.com/cyberpunk2077/mods/5544?tab=files) | 1.0 or newer | Every outfit the game's own shops sell |
| Iconic Shops | [7215](https://www.nexusmods.com/cyberpunk2077/mods/7215?tab=files) | 3.6.1 or newer | Every iconic item, 74 clothes among them |
| Zenitex Virtual Atelier | [10090](https://www.nexusmods.com/cyberpunk2077/mods/10090?tab=files) | 4.13 or newer | ScorpionTank's Zenitex military gear |
| Zenitex Ballistic Mask, Tactical Harness, Combat Jacket, Armor Pads, Panam Pants, Combat Gloves, and Comfy Boots | [12422](https://www.nexusmods.com/cyberpunk2077/mods/12422?tab=files), [9774](https://www.nexusmods.com/cyberpunk2077/mods/9774?tab=files), [19119](https://www.nexusmods.com/cyberpunk2077/mods/19119?tab=files), [12044](https://www.nexusmods.com/cyberpunk2077/mods/12044?tab=files), [10842](https://www.nexusmods.com/cyberpunk2077/mods/10842?tab=files), [19432](https://www.nexusmods.com/cyberpunk2077/mods/19432?tab=files), [11212](https://www.nexusmods.com/cyberpunk2077/mods/11212?tab=files) | 4.1, 4.0, 2.0.1, 4.1, 4.0, 2.0.1, 1.1 | Seven of the outfits the Zenitex store sells: each main file (not Alt. Colors or GS); for Comfy Boots, the Female V and Male V file |
| Zenitex Military Combat Armor, Ballistic Vest, Combat Boots and Underwear | [13212](https://www.nexusmods.com/cyberpunk2077/mods/13212?tab=files), [14348](https://www.nexusmods.com/cyberpunk2077/mods/14348?tab=files), [14781](https://www.nexusmods.com/cyberpunk2077/mods/14781?tab=files), [20394](https://www.nexusmods.com/cyberpunk2077/mods/20394?tab=files) | 3.3, 3.6, 3.4, 1.5 or newer | Four more Zenitex outfits, each main file (not Garment Support or Alt. Colors) |
| Zenitex Ops-Core FAST Helmet, Pistol Holsters and Backpack | [13557](https://www.nexusmods.com/cyberpunk2077/mods/13557?tab=files), [18002](https://www.nexusmods.com/cyberpunk2077/mods/18002?tab=files), [18152](https://www.nexusmods.com/cyberpunk2077/mods/18152?tab=files) | 3.4, 1.5, 1.5 or newer | Three more, each main file; they need Phantom Liberty, and are left out without it |
| Zenitex Combat Goggles and Balaclava Pack | [17049](https://www.nexusmods.com/cyberpunk2077/mods/17049?tab=files), [17411](https://www.nexusmods.com/cyberpunk2077/mods/17411?tab=files) | 1.4, 2.1 or newer | Military accessories: goggles and balaclavas, each main file |
| The RVC00N Dumpster 3 | [25981](https://www.nexusmods.com/cyberpunk2077/mods/25981?tab=files) | 21.0.0 or newer | PinkyDude's store: on computers, and at its own shop behind Dakota's garage (VendorsXL) |
| The RVC00N Dumpster: Goliath Coat and Cityfolk Hoodie | [36516](https://www.nexusmods.com/cyberpunk2077/mods/36516?tab=files), [37493](https://www.nexusmods.com/cyberpunk2077/mods/37493?tab=files) | 1.0.0, 1.0.2 or newer | Two of PinkyDude's garments for game 2.5 |
| The RVC00N Dumpster: the other 24 garments its store sells | [26000](https://www.nexusmods.com/cyberpunk2077/mods/26000?tab=files), [26996](https://www.nexusmods.com/cyberpunk2077/mods/26996?tab=files), [27128](https://www.nexusmods.com/cyberpunk2077/mods/27128?tab=files), [27304](https://www.nexusmods.com/cyberpunk2077/mods/27304?tab=files), [33439](https://www.nexusmods.com/cyberpunk2077/mods/33439?tab=files), [34748](https://www.nexusmods.com/cyberpunk2077/mods/34748?tab=files), [27709](https://www.nexusmods.com/cyberpunk2077/mods/27709?tab=files), [27736](https://www.nexusmods.com/cyberpunk2077/mods/27736?tab=files), [31662](https://www.nexusmods.com/cyberpunk2077/mods/31662?tab=files), [20042](https://www.nexusmods.com/cyberpunk2077/mods/20042?tab=files), [12757](https://www.nexusmods.com/cyberpunk2077/mods/12757?tab=files), [26048](https://www.nexusmods.com/cyberpunk2077/mods/26048?tab=files), [26873](https://www.nexusmods.com/cyberpunk2077/mods/26873?tab=files), [31111](https://www.nexusmods.com/cyberpunk2077/mods/31111?tab=files), [16402](https://www.nexusmods.com/cyberpunk2077/mods/16402?tab=files), [26049](https://www.nexusmods.com/cyberpunk2077/mods/26049?tab=files), [26050](https://www.nexusmods.com/cyberpunk2077/mods/26050?tab=files), [26818](https://www.nexusmods.com/cyberpunk2077/mods/26818?tab=files), [35536](https://www.nexusmods.com/cyberpunk2077/mods/35536?tab=files), [26982](https://www.nexusmods.com/cyberpunk2077/mods/26982?tab=files), [32638](https://www.nexusmods.com/cyberpunk2077/mods/32638?tab=files), [32329](https://www.nexusmods.com/cyberpunk2077/mods/32329?tab=files), [28660](https://www.nexusmods.com/cyberpunk2077/mods/28660?tab=files), [27455](https://www.nexusmods.com/cyberpunk2077/mods/27455?tab=files) | the current file of each | Knife Bandolier, Bunny Slippers, Saul's Pants, Collarless CrystalJock Bomber, Master Chief Evolved Suit, Indiana Jones Outfit, The Fifth Element Collection (its ALL IN ONE file), Cityfolk Short Jacket, Jackie's Jacket, Stinky Burnt Top, Stinky Slashed Top, Stinky Croptop, Yeehaw Collar Shirt, Chuckwalla Tight T-Shirt, Stinky Mechanic Pants, Stinky Quilted Pants, Stinky Bootcut Jeans, Stinky Leather Jeans, David Martinez's Pants, Yeehaw Spur Boots, Latex Succubus Tail, Trauma Team Jumpsuit, Dexter DeShawn's outfit (Pants, Vest and Shoes), PinkyBlume Croptop Shirt |
| Street Ninja Remake: its MAIN file and its Streetwear Shop | [36978](https://www.nexusmods.com/cyberpunk2077/mods/36978?tab=files) | 1.14.0, 1.12.0 or newer | 652 streetwear pieces for both V, in four layers |
| Nola Dreamer's Accessories store, with AirPods Max and six accessories | [14299](https://www.nexusmods.com/cyberpunk2077/mods/14299?tab=files), [28288](https://www.nexusmods.com/cyberpunk2077/mods/28288?tab=files), [14371](https://www.nexusmods.com/cyberpunk2077/mods/14371?tab=files), [16722](https://www.nexusmods.com/cyberpunk2077/mods/16722?tab=files), [11685](https://www.nexusmods.com/cyberpunk2077/mods/11685?tab=files), [15704](https://www.nexusmods.com/cyberpunk2077/mods/15704?tab=files), [14324](https://www.nexusmods.com/cyberpunk2077/mods/14324?tab=files), [14269](https://www.nexusmods.com/cyberpunk2077/mods/14269?tab=files) | 1.8, 1.1 and the current file of each | AirPods Max, Barbed accessories, Bracelets collection, heart choker and garters, Mini dress and glasses, Moon accessories, Spiked Collar. The store sells the glasses of Mini dress and glasses; Nola Dreamer Virtual Boutique (below) sells the dress |
| Nola Dreamer Virtual Boutique: ND_female_virtual_boutique | [5114](https://www.nexusmods.com/cyberpunk2077/mods/5114?tab=files) | 7.6 or newer | Nola Dreamer's clothes store; of what the set installs, it sells the mini dress |

**Hair** (the character creator, a mirror in an apartment, or a ripperdoc)

| Mod | Nexus | For game 2.5 | What it is |
| --- | --- | --- | --- |
| Preem Hair: its 2K file | [8223](https://www.nexusmods.com/cyberpunk2077/mods/8223?tab=files) | 3.0.0 or newer | Sharper textures for the game's own hairstyles, V's and NPCs' (it replaces them) |
| Wolfcut Hair Collection: Messy Wolfcut, Emo Wolfcut, Hime Short, Hime Medium and Hime Long Jelly, each its CCXL file | [16697](https://www.nexusmods.com/cyberpunk2077/mods/16697?tab=files) | 2.0 or newer | 14 wolfcut hairstyles with physics; Messy and Emo for both V, the Hime cuts for Fem V |
| Subleader Hair Pack: its AllInOne file | [19268](https://www.nexusmods.com/cyberpunk2077/mods/19268?tab=files) | 1.09 or newer | 14 hairstyles for Fem V (a rar archive) |
| Hyst Hair Collection: its ALL IN ONE file | [21766](https://www.nexusmods.com/cyberpunk2077/mods/21766?tab=files) | 1.2 or newer | 7 hairstyles for Fem V |
| Original Collection (meluminary): its HAIR MEGAPAK | [19197](https://www.nexusmods.com/cyberpunk2077/mods/19197?tab=files) | 5.0.0 or newer | 20 hairstyles for Fem V |
| Undercut Hair Collection: HAIR 01 to 04 | [19907](https://www.nexusmods.com/cyberpunk2077/mods/19907?tab=files) | 1.0, 1.0, 1.0, 1.1 or newer | Four undercuts for Masc V |

**Vehicles** (Virtual Car Dealer, on in-game computers)

| Mod | Nexus | For game 2.5 | What it is |
| --- | --- | --- | --- |
| Virtual Car Dealer | [4454](https://www.nexusmods.com/cyberpunk2077/mods/4454?tab=files) | 2.3.0 or newer | The car dealer; it sells the vehicles of the mods below |
| Vehicle Pack - Basic: Car Pack 1 and Car Pack 2 | [4625](https://www.nexusmods.com/cyberpunk2077/mods/4625?tab=files) | 1.8.2 and 1.9.0 or newer | About 20 cars built from the game's own models, in many variants |
| Cyberpunk Bikes - Edge | [14719](https://www.nexusmods.com/cyberpunk2077/mods/14719?tab=files) | 1.03 or newer | A lore-friendly bike with 10 appearances |
| Bikes of the Dark Future: Arch V4, its main file BDF_DRe_ArchV4, with Vehicle Exit Fix | [18736](https://www.nexusmods.com/cyberpunk2077/mods/18736?tab=files), [22786](https://www.nexusmods.com/cyberpunk2077/mods/22786?tab=files) | 1.3, 1.0 or newer | 52 Arch V4 bikes |
| Toyota Supra Mk5 HKS Widebody, with Vehicle manufacturer fix | [12652](https://www.nexusmods.com/cyberpunk2077/mods/12652?tab=files), [28744](https://www.nexusmods.com/cyberpunk2077/mods/28744?tab=files) | 1.0.5, 1.0 or newer | A Supra with an HKS body kit |
| Porsche 911 GT3 RS, its Main File, with Material and Texture Override's Legacy file | [11180](https://www.nexusmods.com/cyberpunk2077/mods/11180?tab=files), [5266](https://www.nexusmods.com/cyberpunk2077/mods/5266?tab=files) | 1.2, 1.2 or newer | A 911 GT3 RS |
| Drive an Aerial Vehicle | [13842](https://www.nexusmods.com/cyberpunk2077/mods/13842?tab=files) | 3.5.0 or newer | Fly AVs and helicopters, with an autopilot; buy them at Virtual Car Dealer |
| Vehicle Customizer (stolen vehicles edition): SVE 3dot0, then its 3dot1 update | [9034](https://www.nexusmods.com/cyberpunk2077/mods/9034?tab=files) | 3.0, 3.1 or newer | Switch a car you own or claim between the appearances the game has for it |
| Apollo Intensa Emozione, Lamborghini Countach LPI 800-4 and Countach Liberty Walk | [37233](https://www.nexusmods.com/cyberpunk2077/mods/37233?tab=files), [37234](https://www.nexusmods.com/cyberpunk2077/mods/37234?tab=files), [37235](https://www.nexusmods.com/cyberpunk2077/mods/37235?tab=files) | 1 or newer | xa1res's cars, tested on 2.5 |
| VAZ Oka Yozakura Sport | [36381](https://www.nexusmods.com/cyberpunk2077/mods/36381?tab=files) | 4 or newer | A VAZ-1111 Oka in a night-sakura livery; hood and hatch on two CET hotkeys you bind |
| Toyota GR Yaris: its All Purpose Drive Spec and its Rocket Bunny Kit | [34357](https://www.nexusmods.com/cyberpunk2077/mods/34357?tab=files) | 3.3, 3.2 or newer | A GR Yaris with an optional widebody kit |
| Nissan Silvia S14 'Marked One', its main file, with Vehicle Manufacturers Resource | [25997](https://www.nexusmods.com/cyberpunk2077/mods/25997?tab=files), [7855](https://www.nexusmods.com/cyberpunk2077/mods/7855?tab=files) | 1.1, 1.1 or newer | A nomad-tuned S14 (a 7z archive) |

**Gameplay**

| Mod | Nexus | For game 2.5 | What it is |
| --- | --- | --- | --- |
| Cyber Drift 2.0, its Light file | [8306](https://www.nexusmods.com/cyberpunk2077/mods/8306?tab=files) | 2.31 or newer | Smoother drifting over a wider range of angles |
| Quick Stash | [30016](https://www.nexusmods.com/cyberpunk2077/mods/30016?tab=files) | 1.1 or newer | Moves your inventory to V's stash or your car in one go (not equipped or quest items) |
| No Intro Videos, its archive file | [533](https://www.nexusmods.com/cyberpunk2077/mods/533?tab=files) | 0.5 or newer | Skips the logo videos at start-up |
| Native Settings UI | [3518](https://www.nexusmods.com/cyberpunk2077/mods/3518?tab=files) | 1.97 or newer | The settings pages of Drive an Aerial Vehicle and Cyber Drift |
| Impact FX | [36631](https://www.nexusmods.com/cyberpunk2077/mods/36631?tab=files) | 0.8.3.3 or newer | Dust, smoke and debris that linger after a gunfight |
| Immersive Audio Distance, its file for 2.5 | [36809](https://www.nexusmods.com/cyberpunk2077/mods/36809?tab=files) | 1.2.0 or newer | Voices, TVs, adverts and radios fade with distance |
| Immersive First Person, its main file | [2675](https://www.nexusmods.com/cyberpunk2077/mods/2675?tab=files) | 2.2.0 or newer | A first-person camera that shows more of V's body, FreeLook (look around without turning V), and a height slider in Cyber Engine Tweaks' overlay |
| Katana Pack 2, its file with every blade | [36164](https://www.nexusmods.com/cyberpunk2077/mods/36164?tab=files) | 1.1 or newer | Seventeen katanas and swords, some with charged attacks (a RAR archive) |
| Curbside | [35922](https://www.nexusmods.com/cyberpunk2077/mods/35922?tab=files) | 1.0.1 or newer | A summoned car or bike comes to your level, stops beside you, and follows you if you walk off |

**Frameworks**, downloaded from GitHub by the script: Mod Settings 0.2.28 (which Virtual
Atelier needs), Audioware 1.11.1 (mods' own sounds), Cyber Engine Tweaks 1.38.1 (Lua mods),
Input Loader 0.2.6 (Let There Be Flight's key bindings), Codeware 1.21.2, TweakXL 1.12.0,
ArchiveXL 1.28.6 and redscript 0.5.32 (the script mods,
NightCoop's included). From Nexus Mods: VendorsXL 2.2.0 and Deceptious Quest Core 3.3.3, which
The RVC00N Dumpster 3's shop in the world needs; Zenitex Core Dependency 5.1.8 ([16356](https://www.nexusmods.com/cyberpunk2077/mods/16356?tab=files), its
main file, not No Camo, Black Decals or a colour set), whose stats and class bonuses every
Zenitex outfit refers to; and Browser Extension 0.9.7 ([10038](https://www.nexusmods.com/cyberpunk2077/mods/10038?tab=files), its
BrowserExtensionFramework file), which lists every site, Virtual Atelier's among them, on
the in-game browser's home page.

**Equipment-EX** (`--with-equipment-ex`, from Nexus Mods,
[6945](https://www.nexusmods.com/cyberpunk2077/mods/6945?tab=files), 1.2.10 or newer, its main file)
wears clothes in layers, such as Street Ninja's four layers.
Every piece of the set is wearable without it, one per game slot. It is a set of its own
because NightCoop lists it as a known overlap: NightCoop sends looks by its slots, so a
partner without it sees other slots, and it overrides photo-mode functions. Use it only if
everyone you play with does. `--without-equipment-ex` removes it again.

With the mod set too, it brings raem's jewellery, made for Equipment-EX's neck, wrist and
hand slots (without it, a ring would take the whole torso slot):

| Mod | Nexus | Version | What it adds |
| --- | --- | --- | --- |
| V's Bullet Necklace, its main file | [15076](https://www.nexusmods.com/cyberpunk2077/mods/15076?tab=files) | 1.1 or newer | V's bullet necklace, with physics |
| Chain Jewelry Collection, its main file | [15861](https://www.nexusmods.com/cyberpunk2077/mods/15861?tab=files) | 1.2 or newer | Six chain necklaces and two bracelets |
| Reyes Accessories, its main file | [17069](https://www.nexusmods.com/cyberpunk2077/mods/17069?tab=files) | 1.1 or newer | Reyes' watch, bracelets and rings |
| The Community Palette Project | [10437](https://www.nexusmods.com/cyberpunk2077/mods/10437?tab=files) | 1.1 or newer | The colours Chain Jewelry and Reyes Accessories use: a bare `.archive`, installed into `archive/pc/mod` |
| raem's Atelier Store: Accessories - Main Store, among the optional files | [14210](https://www.nexusmods.com/cyberpunk2077/mods/14210?tab=files) | 2.0 or newer | The store that sells them (not raem's other stores, which would stay empty) |

A download older than its minimum is passed over, with the reason. Nexus Mods does not let
scripts download files (a browser check, and an API that needs each user's key; downloads
through it need Premium),
so you download the Nexus mods yourself:

1. Run `nightcoop-install --with-mods`. It installs the frameworks from GitHub and prints
   the Nexus page of each mod you have not downloaded yet, and which file to take where a
   mod has several.
2. Sign in to Nexus Mods (a free account is enough). On each page's Files tab, choose
   **Manual download**. Keep the name Nexus gives the file: it holds the mod's ID, which is
   how the script recognises it. Both of Nexus's names are understood
   (`Name-ID-version-time.zip`, and since 2026 `Name ID version date key.zip`), also when
   the browser adds " (1)" or the spaces became underscores.
3. Run the script again. It finds the files in your Downloads folder (or the folder given
   with `--mods-from`) and installs them. It keeps a copy in
   `~/.cache/nightcoop-linux/mods`, so you may delete the downloads. To update one of
   these mods later, download its newer file and run the script again.

Each archive's game folders (`archive`, `bin`, `engine`, `mods`, `r6`, `red4ext`) are
installed, without read-me files or installer data, also when an archive wraps them in a
folder of its own. An archive without game folders that holds only `.archive` and `.xl` files
(and notes), at its root or in one folder, is installed into `archive/pc/mod`, as mod
managers do; one with such files in several folders (versions to choose from) is passed
over. Zip archives need nothing extra; 7z and RAR archives are unpacked with
`bsdtar` from libarchive, which SteamOS, CachyOS and Arch include. A download the script
cannot use (damaged, without game folders, or a 7z or RAR archive with no `bsdtar`) is
reported and passed over for an older copy, if there is one. A mod whose requirement is
missing is left out with a warning; for example, a store without Virtual Atelier would
stop redscript from compiling every script, NightCoop's included.

**What the mods write while you play stays yours.** Drive an Aerial Vehicle keeps its
settings, the AVs you own and the map it learns as you fly in `Data/`; Cyber Drift keeps
its car lists and drift models in `custom/`; Vehicle Customizer keeps the appearances you
chose; every Cyber Engine Tweaks mod may keep a `db.sqlite3`. Reruns and updates leave these as they are. A file is replaced only when a
new release of the mod changes the file it ships, and your copy is backed up first.

**How the set stays compatible with NightCoop:**

- **Mod Settings, which Virtual Atelier needs.** NightCoop's guide lists it as replacing
  the pause, death and main menus, where NightCoop's co-op entry lives. Its releases for
  2.5 (0.2.22 and later) no longer replace them: they add their entry beside the game's
  and call the game's own functions. Check once that the co-op entry is still in the main
  and pause menus. (Earlier versions of this script installed Virtual Atelier's Basic
  file to avoid Mod Settings, but that edition ended with 1.2.4 in 2024; every release
  since needs Mod Settings.)
- **Clothing.** NightCoop sends your look by its items. A.G.I.S., Night City Marketplace,
  All Vanilla Clothes and Iconic Shops sell the game's own items, which every partner's game
  has (Phantom Liberty pieces only where the partner owns it). An outfit of a mod shows for a
  partner only when they have the same outfit mod; otherwise NightCoop shows a plain game
  piece for that body part, and head, face and accessories stay empty.
- **Clothes that ask for Equipment-EX** still work without it. In every outfit of the set,
  each item keeps a game slot first (checked in each mod's TweakXL files): Equipment-EX
  only adds its own slots, so that layered pieces can be worn together. NightCoop sends
  looks by the game slot when Equipment-EX is absent. This also holds for the seven Zenitex
  outfits whose pages list Equipment-EX, which earlier versions of this script left out
  (an earlier note here said ten); the set has them now. NC Fashion's store lists
  Equipment-EX as mandatory and is left out.
- **Hairstyles.** NightCoop draws a partner's V from their character-creator choices, with
  your game's own files, and leaves out an option your game does not have. Preem Hair
  replaces the textures of the game's own hairstyles: a partner without it sees the game's.
  The other hair mods add hairstyles to the character creator (ArchiveXL's CCXL; choose them
  there, at a mirror or at a ripperdoc), so a partner without the same mod sees your V
  without that hairstyle. Keep the mod set the same for everyone, and switch V to a game
  hairstyle before you remove the set.
- **Phantom Liberty.** Three Zenitex pieces need it: the Ops-Core FAST Helmet, the Pistol
  Holsters and the Backpack. So does Iconic Shops, which sells the expansion's iconic items
  too. Without the expansion (no `archive/pc/ep1` in the game folder) the installer leaves
  them out and says so; a partner without it sees no helmet, and plain game pieces for the
  others.
- **Zenitex Core Dependency** holds the stats and class bonuses that every Zenitex outfit's
  items refer to (checked in each outfit's TweakXL files; eight of their pages list it).
  Earlier versions of this script installed the outfits without it; they are now left out
  until it is downloaded.
- **The RVC00N Dumpster 3, VendorsXL and Deceptious Quest Core.** VendorsXL places vendors
  in the world. It replaces the game's vendor restocking for every vendor, with a copy that
  raises stock limits; NightCoop does not list that function. Deceptious Quest Core is
  quest data (a journal and a streaming block), and the store adds its shop area and a
  computer to the world. Everyone in a session should have them, like the outfits.
- **Clothes made for photo mode are left out**, by their authors' own words: Veegee's ("My
  clothes are made for photo mode"), with Veegee Shop 3, which sells only them, and the Dolly
  Go-Go Mini Set ("intended for Photo Mode rather than regular gameplay"). Their downloads are
  passed over; a game folder where an earlier version installed them loses them on the next
  run. Two of Nola Dreamer's accessories are marked adult on Nexus and are left out too; the
  store skips them.
- **Cars and AVs of mods.** A partner sees your modded car, or your Drive an Aerial Vehicle
  AV, only when they have the mod that adds it; otherwise NightCoop shows a game vehicle
  with as many seats in its place. A car bought from Virtual Car Dealer opens in a guest's
  garage in the host's world: NightCoop reads its name from the mod's own TweakXL files.
  So the simplest rule is the same mods for everyone. Drive an Aerial Vehicle's hooks call
  the game's own functions, its hook on dialogue choices included, which NightCoop relies
  on. Several of the vehicle mods have not been updated since before patch 2.5: Vehicle
  Pack - Basic (2023), the Porsche (2023), Material and Texture Override (2023), and
  Bikes of the Dark Future with its Vehicle Exit Fix, which was made for patch 2.3. Vehicle
  mods are mostly data and usually outlast patches, but try each once.
- **This round's cars.** Their scripts wrap game functions and call the originals: the
  speedometer and tachometer of the HUD, and the Countach's spoiler and air brake (none in
  NightCoop's tables). They are built on game vehicles with the game's seats, so a partner
  riding along sits properly. The VAZ Oka's hood and hatch hotkeys are unbound until you
  bind them in Cyber Engine Tweaks. The GR Yaris and the Silvia are data only. The Silvia
  also ships a file for Dedka Car Dealership, which Dedka reads if you install it and is
  inert otherwise. The GR Yaris's newest kit (3.2) is a version behind its main file (3.3),
  and the car was tested on 2.31; try the kit once.
- **Six cars are left out: the Porsche 992 GT3 R and SDH0's five Garage cars** (Porsche 911
  Targa 4 GTS, Porsche Singer 911 Armed and three Mazda RX7s). They need AudioXL for their
  engine sounds, and AudioXL watches whichever player body appeared last. NightCoop's
  partners' bodies are player bodies too, so in co-op AudioXL's underwater muffling can
  follow a partner instead of you.
- **Impact FX** wraps hit and attach functions and calls the originals. When a partner's
  body appears it re-applies its own local settings once. Its smoke and debris are local:
  each player with the mod sees their own.
- **Immersive Audio Distance** hooks nothing. It retunes how far sounds carry in the game's
  audio data when that loads, in your game only.
- **Customising a car.** Vehicle Customizer switches a car between the appearances the
  game itself has for it, so the appearance exists in every partner's game; NightCoop
  shows partners your car's appearance and its CrystalCoat paint (the game's own colour
  system). It works only with the game in English. Car Modification Shop, the most
  endorsed vehicle mod, is left out: it changes performance only, and its author says it
  does not work with Let There Be Flight.
- **Native Settings UI** adds its menu entry through the same function as NightCoop's
  co-op entry and calls the original, which NightCoop's guide names as the safe way.
- **Audioware** is on NightCoop's list of mods it recognises (it hooks the time system,
  saving and menus). Its author lists issues on some Wine setups; if mods' sounds stay
  silent under Proton, that is the likely cause.
- **Cyber Drift** changes only how your own car handles. Partners' cars in your game are
  mirrors that NightCoop moves, so their handling is not affected. Its files are labelled
  for game 2.31 and have not been updated for 2.5 yet.
- **No Intro Videos**: the archive file replaces the start-up videos rather than hooking
  the game. The script never installs its redscript file, which hooks the start-up where
  NightCoop skips the intro itself.
- **Browser Extension** only adds to the in-game browser: its hooks wrap the browser's
  functions and call the originals, and none is in NightCoop's tables. An earlier note
  here said players report it broken since patch 2.3 and left it out; that was wrong for
  2.3, which its 0.9.6 fixed. Its last release (0.9.7, September 2025) predates patch 2.5,
  and its page names 2.31 as tested, though players report it working on 2.5 and
  Fullscreen Browser's 2.5 release requires it. Try it once.
- **Immersive First Person** changes only your own camera. Its hooks observe or wrap game
  functions and call the originals. Its plugin hooks one native function, which is not
  among those NightCoop detours. NPCs look at your V's face rather than its chest;
  partners' bodies keep the game's aim. Its height slider is at 0 cm until you move it; a
  partner without the mod sees your V at the game's height.
- **Katana Pack 2.** A partner without it sees a game blade of the same kind in your hands
  (NightCoop's fallback for weapons), and the charge effects show only on your screen. The
  hits count for everyone, as damage claims. Its scripts wrap the game's melee, charge and
  damage functions and call the originals; none is in NightCoop's tables. One blade, the
  Cyberfang, can also shock enemies hit by bullets it deflects. In co-op that shock would
  show only on your screen for NPCs a partner leads, but its chance is 0 as shipped.
- **Curbside** drives only your own summoned car. A partner sees it arrive through
  NightCoop's car sync, including the jumps it makes when it moves a car out of sight.
- **CPU Optimization (and its Plus edition) is left out.** It makes crowds spawn and
  despawn around V, while in co-op the host leads the crowd for every player, so NPCs
  would pop in and vanish near partners. The Plus edition also needs the Ultra Plus
  graphics mod. Its v3 is no different: each of its four files turns pedestrians off, lets
  crowds spawn in view (NightCoop keeps them from popping in where any player looks), and
  changes how police cars chase, which the host leads too.
- **Cyberware-EX and Immersive Third Person are left out for now**: each needs a small
  bridge first. Cyberware-EX replaces the function that starts focus-mode slow motion
  (NightCoop's "time and pause" table) and starts it while a Sandevistan runs, which in a
  session would slow the shared world. Immersive Third Person switches the camera from
  callbacks of player bodies, and partners' bodies are player bodies too, so a partner
  changing view would move yours. A bridge can skip both in a session, through NightCoop's
  SDK; none is shipped until it has been compiled and tried.
- **Equipment-EX NightCoop Compatibility Bridge is left out.** It replaces NightCoop's
  plugin (`red4ext/plugins/NightCoop/NightCoop.dll`) with a copy of 0.2.0-beta whose machine
  code is patched in nine places. It works only with that release and Equipment-EX 1.2.10,
  every player must install it, and its author lists its current release as untested in
  game. NightCoop asks mods to ship only their own files. If you install it by hand,
  `check` reports NightCoop's plugin as changed, and the next run puts the official one back
  (the other is kept in the backup).
- **Quick Stash in co-op:** everyone in a session plays in the host's world, so the stash a
  guest opens there is not the guest's own. Move items in your own game, or as the host;
  the script reminds you of this.
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
  replaces. redscript and Audioware have no readable version, so they are always the
  paired build.
- **Removing them:** `--without-flight` removes Let There Be Flight unless the mod set is
  on, and `--without-mods` removes the mods of the set, those inside Cyber Engine Tweaks'
  folder too, and Let There Be Flight unless `--with-flight` is on. The
  frameworks stay, Native Settings UI among them, because many other mods need them.
  `uninstall` removes everything the script installed and puts back the game files it
  replaced: the game's script compiler, which redscript replaces, and the input files
  Input Loader changes.
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
  are; change them under Properties if you wish (the line from before the first install is
  in its backup folder, `launch-options.txt`). Saves are never touched.
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
- **Steam shows the game as running for a moment, and nothing starts.** A wrapper in the
  launch options failed, often `game-performance` or `mangohud` where they are missing.
  `check` names the one that cannot run; rerun the script with Steam closed to take
  `game-performance` out, or add `--no-mangohud`.
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
Tweaks' loader its override and listed the Nexus downloads, and a rerun changed nothing.
The test suite passes on all three systems.

**Not covered:**

- the real game on real hardware, with a GPU and the main menu;
- the Nexus Mods files, which scripts cannot download without Premium. Their names,
  contents, versions and requirements were read through the Nexus Mods API, and the
  tests use archives named and laid out like them; the mods' support for patch 2.5 comes
  from their pages and changelogs.

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
- the launch options' wrappers, with stand-ins for their programs:
  - `game-performance` added on CachyOS, and taken out where it cannot run (SteamOS,
    Flatpak Steam, no power-profile tool it supports), with `--no-game-performance`
    remembered;
  - `--mangohud` and `--no-mangohud`, refused on SteamOS, taken out where MangoHud cannot
    run, and with Flatpak Steam only when the extension for Steam's runtime is installed;
  - `--redmod`: `-modded` only when asked, remembered, and taken out by `--no-redmod`; an
    earlier `-modded` dropped with a note; REDmod mods in `mods/` named; the REDmod DLC
    and the deploy;
- a hand-copied old NightCoop build;
- updates in place: nothing changed when current, only differing files replaced, saves
  copied once, `--force` and `--backup-saves`;
- the flight set:
  - paired with the game patch, and left as it is on an unknown patch;
  - a newer copy installed by hand kept;
  - `--without-flight` removing only Let There Be Flight;
  - the mod set bringing Let There Be Flight, `--without-flight` leaving it there while the
    mod set is on, and `--without-mods` taking it out;
  - an archive with the wrong SHA-256 refused;
- the mod set:
  - the frameworks from GitHub, Cyber Engine Tweaks' override from the first run;
  - the Nexus files under both of Nexus's names, as the browser saves them, found in the
    Downloads folder (a localised one too) and installed from the script's own copy once
    they are deleted;
  - the file to take of a mod with several (Cyber Drift's Light file, A.G.I.S.'s main
    file, No Intro Videos' archive file, the Zenitex outfits' main files), two files of one
    mod as two components (Vehicle Pack - Basic's car packs), an update file on top of its
    main file (Vehicle Customizer), and downloads older than the patch needs passed over;
  - files the mods write while playing kept, and replaced only by a release that changes
    them;
  - a missing requirement leaving a mod out, and missing downloads listed;
  - an archive wrapped in a folder, and a damaged one or one without game folders passed
    over for a copy that works;
  - `--without-mods` removing only the mods, those inside Cyber Engine Tweaks' folder
    too, while the flight set keeps the frameworks it shares;
  - the mods added in 3.4.0 (six cars, the clothes of three stores, Impact FX, Immersive
    Audio Distance) from archives with the real downloads' names and entries, as read from Nexus:
    each mod's file rule against its other files, folders that wrap an archive, read-me
    files and code lists left out, a missing requirement holding its store back, and the
    photo-mode clothes passed over;
  - mods that an earlier version installed and the set no longer has, removed on the next
    run, by name;
- Zenitex's military gear, Nola Dreamer's boutique and the hairstyles, with the
  files each rule passes over (Preem Hair's 4K file, Garment Support and Alt. Colors files,
  single hairs beside an all-in-one file, old replacer versions, raem's other stores), and
  the Zenitex pieces that need Phantom Liberty left out, with the reason, where it is missing;
- Equipment-EX: only with `--with-equipment-ex`, alone or with the mod set, and removed
  again with `--without-equipment-ex`; raem's jewellery only with both;
- what the mods need: Zenitex Core Dependency for the Zenitex outfits (not its colour sets),
  The Community Palette Project for the jewellery (a bare `.archive` installed into
  `archive/pc/mod`, and bare files in two folders passed over), Phantom Liberty for Iconic
  Shops; Immersive First Person (not its file for Immersive Third Person), Katana Pack 2's
  file with every blade, Browser Extension's framework file and Curbside;
- the fixtures' add-on table matching the installer's, so that a change to one shows;
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
