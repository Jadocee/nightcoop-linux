# Test sandboxes

Containers that recreate the environments the installer was verified in, so that the
checks can be repeated whenever Proton, RED4ext, NightCoop, Microsoft's runtime, SteamOS
or the installer itself changes. Everything runs with Docker Compose from the repository
root:

```bash
docker compose -f sandbox/compose.yaml run --rm --build <service>
```

| Service | Image | What it does |
| --- | --- | --- |
| `arch` | Arch Linux | Runs the test suite (`tests/run-tests.sh`) |
| `cachyos` | CachyOS (`cachyos/cachyos`) | Runs the test suite on CachyOS's own package builds |
| `steamos` | SteamOS 3.8, from Valve's repositories | Runs the test suite on SteamOS's Python, Bash and coreutils |
| `package` | Arch Linux with `makepkg` and `namcap` | Builds `packaging/arch/PKGBUILD` from the current commit, lints it, checks `.SRCINFO` |
| `experiments` | CachyOS with `proton-cachyos`, Xvfb and MinGW | The README's verification matrix, with real Proton (online) |
| `install-and-launch` | the same | The whole user journey for game patch 2.5, with both mod sets and real Proton (online) |

The repository is mounted read-only at `/src`. The `package` service builds the last
commit, not uncommitted changes. Each service exits 0 on success and 1 when a check fails.
The image builds run each `pacman` step up to four times, so a package server that times
out once does not fail the build.

## The real-Proton services

Neither service needs the game. A stand-in `Cyberpunk2077.exe`, built with MinGW from
[`e2e/stub/`](e2e/stub), carries the real executable's version resource for each patch
(file version 3.0.88.46235 for 2.5) and imports `winmm.dll` like the game does. RED4ext therefore loads into it and runs its start-up exactly as in the
game, then stops at the point where it would hook the game's code; the stand-in has none.
The scripts start the stand-in through Proton (`proton runinprefix`), on a virtual X
display, and classify the result:

| Result | Meaning |
| --- | --- |
| `started` | RED4ext's log shows it initialising: its loader and the C++ runtime work |
| `error998` | The loader's "RED4ext (error 998)" dialog: `RED4ext.dll` failed while loading |
| `refused` | RED4ext rejected the game patch ("ensure your game is updated to patch …"), as a release that does not support it would |
| `notloaded` | Wine used its own `winmm.dll`, so RED4ext's loader never ran |

A plain "RED4ext" dialog after `started` is expected: it is RED4ext stopping at the
missing game code.

**`experiments`** (about a minute once the image exists) reproduces the matrix below and
fails if any row changes. A failure means an assumption the installer is built on no
longer holds, for example a Proton update that changes how Wine picks DLLs.

| Scenario | Expected |
| --- | --- |
| NightCoop unpacked, no override | `notloaded` |
| The installer's registry override (works with Steam open) | `started` |
| The launch-option override (`WINEDLLOVERRIDES`) | `started` |
| Steam's first-launch VS 2019 runtime (14.29) | `error998` |
| VS 2022 (14.44) or v14 (14.51) runtime over it | `started` |
| Steam's VS 2019 installer run again afterwards | runtime kept, `started` |

**`install-and-launch`** builds, for each patch, a Steam home as it is after the game's
first launch: a Proton prefix with Steam's VS 2019 runtime, no overrides and no Proton
build chosen. It then:

1. runs `nightcoop-install.sh install --yes --with-flight` as an ordinary user, against
   the live nightcoop.net, GitHub and Microsoft;
2. checks what `check` reports, including the Let There Be Flight build paired with the
   patch and the mods it needs;
3. runs it again as `update`, which must find everything current and change nothing;
4. starts the stand-in with the registry override alone, as when Steam is open, and with
   the launch options, as when Steam is closed;
5. adds `--with-mods`, which must install the mod set's frameworks from GitHub, give
   Cyber Engine Tweaks' loader the same override, and list the Nexus-only mods with their
   pages (they cannot be downloaded by a script), and a rerun must then change nothing.
   This comes after the launches, because Cyber Engine Tweaks would load into the stand-in.

The versions it expects are read from the installer's `ADDON_SETS` table. `PATCHES` names
the patches to run; a new patch needs its stand-in first (see *Keeping it current*).

Both services download NightCoop from nightcoop.net (the build listed for each patch in
`releases.json`) and the runtime installers from Microsoft; `install-and-launch` also
downloads both mod sets' GitHub releases. The weekly run therefore notices when a pinned
release changes or disappears. The downloads are cached in the `downloads` volume between
runs.

**Not covered:** rendering, the real game, the NightCoop plugin itself (RED4ext loads
plugins only after hooking the game) and Valve's own Proton builds, which are only
available through Steam. `proton-cachyos` is built from Valve's Proton and uses the same
`proton` script.

## Options

| Variable | Default | Effect |
| --- | --- | --- |
| `STEAMOS_BRANCH` | `3.8` | SteamOS release for the `steamos` image; the image is rebuilt with that release's repositories |
| `PATCHES` | `2.5` | Game patches for `install-and-launch` |
| `PROTON_TOOL` | `proton-cachyos-native` | Proton folder under `/usr/share/steam/compatibilitytools.d` for the real-Proton scripts |

For example: `STEAMOS_BRANCH=3.9 docker compose -f sandbox/compose.yaml run --rm --build steamos`.

## Behind a proxy

If the internet is reachable only through a proxy, add
[`compose.proxy.yaml`](compose.proxy.yaml). It covers a proxy on the host's own
localhost, and one that inspects TLS. It builds and runs on the host's network, passes
`HTTP(S)_PROXY` and `NO_PROXY` in, and makes the images trust the CA in `EXTRA_CA_PEM`.
Building on the host's network needs bake's `network.host` permission, so build with bake
first:

```bash
export EXTRA_CA_PEM="$(cat /path/to/proxy-ca.pem)"   # only for a TLS-inspecting proxy
F="-f sandbox/compose.yaml -f sandbox/compose.proxy.yaml"
docker compose $F build --print experiments | docker buildx bake -f - --allow=network.host --load
docker compose $F run --rm experiments
```

`EXTRA_CA_PEM` should hold just the proxy's CA certificate(s). An environment variable
cannot hold more than 128 KiB, so a full system CA bundle will not fit.

## Keeping it current

- **A new game patch:** add its file and fixed product versions to `PATCHES` in
  [`e2e/stub/build.sh`](e2e/stub/build.sh), and the RED4ext release that targets it to
  `RED4EXT_COMPAT` in the installer. The version constants are
  `RED4EXT_V1_RUNTIME_VERSION_*` in RED4ext.SDK's `include/RED4ext/Api/v1/Runtime.hpp`.
  Then add the patch to `PATCHES`, and its lines to `ADDON_SETS` in the installer (next
  bullet).
- **A new release of a GitHub-hosted add-on** (Let There Be Flight, Input Loader,
  ArchiveXL, TweakXL, redscript, Codeware, Cyber Engine Tweaks): update its line in
  `ADDON_SETS`: the version, the archive's URL and its SHA-256. The game patch a release
  supports is in the project's README or release notes at that tag. For Let There Be
  Flight and Input Loader, it is also the "Built for" version in the DLL
  (`nightcoop-install __py pestr <dll> Comments`). For Cyber Engine Tweaks, it is
  `Image::GetSupportedVersion()` in its source.
- **The Nexus-only mods** have no pinned version: the installer takes the newest file of
  each that the user has downloaded. For a new game patch, check each mod's page, and add
  its line for the patch only once it supports it.
- **A new SteamOS release:** set `STEAMOS_BRANCH`; the image uses whichever of Valve's
  repositories exist for it.
- **A new Proton or NightCoop build:** rebuild with `--build`; the images take the current
  packages and the scripts take the current `releases.json`.

CI runs these services from [`../.github/workflows/sandbox.yml`](../.github/workflows/sandbox.yml):
every week, when the sandbox or the installer changes, and on demand.
