# Building MQTTy on macOS

> **Status:** unofficial, best-effort. macOS is not a release target. There is
> no Homebrew formula, no signed bundle, and no notarization. Use the recipe
> below for local development or personal use.

## TL;DR

```sh
./build-aux/macos-build.sh
open build/MQTTy.app
```

If macOS refuses to launch the bundle on first run, right-click
`build/MQTTy.app` in Finder, choose **Open**, then confirm in the dialog. The
warning is from Gatekeeper because the bundle is unsigned; once accepted, it
is remembered.

## What the script produces

| Path                              | Description                              | Size  |
| --------------------------------- | ---------------------------------------- | ----- |
| `build/install/bin/MQTTy`         | Plain CLI binary (Mach-O, arm64 or x86_64) | ~1.3 MB |
| `build/install/share/...`         | GResource, GSettings schemas, icons      | ~56 KB |
| `build/MQTTy.app`                 | Double-clickable bundle                  | ~1.5 MB |
| `build/AppIcon.icns`              | Multi-size icon generated from SVG       | ~178 KB |

The bundle depends on the GTK runtime from Homebrew via absolute paths
(`/opt/homebrew/...` on Apple Silicon, `/usr/local/...` on Intel). Copying it
to a Mac without the same Homebrew packages will fail at launch with a
`dyld: Library not loaded` error.

## Prerequisites

- macOS 11 (Big Sur) or newer.
- [Homebrew](https://brew.sh).
- A Rust toolchain (`rustup` is recommended). The script does not install
  Rust because most macOS developers manage it outside Homebrew.

The script installs the following Homebrew packages on first run:

| Package               | Why                                                              |
| --------------------- | ---------------------------------------------------------------- |
| `meson`, `ninja`      | Build system used by the project                                 |
| `gtk4`                | Core GUI toolkit                                                 |
| `libadwaita`          | GNOME widget library (>= 1.6)                                    |
| `gtksourceview5`      | Embedded code editor widget                                      |
| `openssl@3`           | Required by `paho-mqtt-c` (keg-only, hence the env vars)         |
| `blueprint-compiler`  | Compiles `data/**/*.blp` into GtkBuilder XML                     |
| `dart-sass`           | Compiles `data/styles/*.scss`                                    |
| `adwaita-icon-theme`  | Provides fallback icons for libadwaita widgets                   |
| `desktop-file-utils`  | Meson requires `update-desktop-database` during configure        |
| `gawk`                | `meson.build` uses gawk-only extensions, BSD awk fails to parse  |

Pass `--no-deps` to the script to skip this step on subsequent runs.

## Manual steps (for reference)

If you want to understand or customize each phase, the script is equivalent
to:

```sh
# 1. Install dependencies (only needed once).
brew install meson ninja gtk4 libadwaita gtksourceview5 openssl@3 \
             blueprint-compiler dart-sass adwaita-icon-theme \
             desktop-file-utils gawk

# 2. Export environment variables.
BREW=$(brew --prefix)
export PATH="$BREW/opt/gawk/libexec/gnubin:$PATH"
export PKG_CONFIG_PATH="$BREW/opt/openssl@3/lib/pkgconfig:$PKG_CONFIG_PATH"
export OPENSSL_ROOT_DIR=$BREW/opt/openssl@3
export OPENSSL_DIR=$BREW/opt/openssl@3

# 3. Configure and build.
meson setup build --prefix=$PWD/build/install -Dprofile=default
ninja -C build
ninja -C build install

# 4. Run the plain binary.
./build/install/bin/MQTTy
```

To then assemble a `.app`, read `build-aux/macos-build.sh`. The bundle layout
is documented in [The .app layout](#the-app-layout) below.

## Lessons learned (the why behind the script)

These are the four issues that needed a workaround. Documenting them so the
next person does not have to rediscover.

### 1. BSD `awk` does not parse the version-extraction script

`meson.build:19-34` extracts the project version from `Cargo.toml` with this
gawk expression:

```awk
match($0, /\s*version\s*=\s*"(.*)"/, arr)
```

The three-argument form of `match` (which populates `arr` with capture
groups) is a gawk extension. macOS ships BSD awk, which errors out with
`illegal statement at source line 3`.

**Fix:** install `gawk` and prepend `$(brew --prefix)/opt/gawk/libexec/gnubin`
to `PATH` so `awk` resolves to the GNU variant. No source change required.

### 2. `openssl@3` is keg-only

Homebrew does not link `openssl@3` into `/opt/homebrew/lib` because macOS has
its own LibreSSL in `/usr/lib`. pkg-config therefore cannot find it without
help.

**Fix:** prepend `$(brew --prefix)/opt/openssl@3/lib/pkgconfig` to
`PKG_CONFIG_PATH`. Also set `OPENSSL_ROOT_DIR` and `OPENSSL_DIR` because
`paho-mqtt-c` builds with cmake, which uses those variables instead of
pkg-config.

### 3. Meson hard-requires `update-desktop-database`

`meson.build:100` calls `gnome.post_install(update_desktop_database: true)`
unconditionally. On macOS this binary is not part of `gtk4`; it lives in
`desktop-file-utils`. Without it, `meson setup` aborts with
`Program 'update-desktop-database' not found`.

**Fix:** install `desktop-file-utils`. The script does this for you.

### 4. `paho-mqtt-c` is flaky on first build

The upstream `msys2-build-portable.sh` already warns about this:

> Sometimes the command works, sometimes not. It fails during Paho MQTT C
> library building, but if you try one or two more tries it just works
> magically.

We have observed the same on macOS. If `ninja -C build` fails inside the
paho cmake step, rerun it. The failure is intermittent and the next attempt
typically succeeds.

## The .app layout

```
MQTTy.app/
  Contents/
    Info.plist
    MacOS/
      MQTTy                       # the unmodified release binary
    Resources/
      AppIcon.icns                # generated from the project SVG
    share/                        # NON-STANDARD location, see below
      MQTTy/MQTTy.gresource
      glib-2.0/schemas/gschemas.compiled
      icons/...
```

### Why is `share/` under `Contents/` instead of `Contents/Resources/`?

`src/main.rs:45-55` derives the data directory from the executable path:

```rust
let root_dir = std::env::current_exe()?
    .parent()?    // MQTTy.app/Contents/MacOS/
    .parent()?;   // MQTTy.app/Contents/
```

It then looks for `share/MQTTy/MQTTy.gresource`, `share/glib-2.0/schemas`,
`share/icons`, and `share/locale` relative to that root. Placing `share/`
directly under `Contents/` makes the existing logic work unchanged. The
"correct" Apple location would be `Contents/Resources/share/`, but that
would require a macOS-specific code path in `main.rs`. The current layout
trades platform purity for zero source diff.

## Known limitations

- **Not portable.** The bundle links against absolute Homebrew paths. To
  distribute to other Macs, every GTK dependency must be vendored into
  `Contents/Frameworks/` with `install_name_tool` rewrites. This is the
  "portable" mode and is not implemented yet.
- **Not signed or notarized.** Gatekeeper will warn on first launch.
- **Single architecture.** The build targets the host architecture only
  (arm64 on Apple Silicon, x86_64 on Intel). No universal binary.
- **Not native-feeling.** The UI follows the GNOME HIG, not the macOS HIG:
  the title bar, menu bar behavior, and keyboard shortcuts are all GTK.

## Possible future work

- A `--portable` flag that vendors all GTK dylibs and rewrites their load
  commands so the bundle runs on a clean Mac. Reference implementation:
  https://github.com/auriamg/macdylibbundler.
- A universal binary by building twice (once per arch) and merging with
  `lipo -create`.
- A Developer-ID-signed and notarized `.dmg` release artifact.
- Submission as a Homebrew cask once the portable bundle exists.
