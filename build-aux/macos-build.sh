#!/bin/bash

# Copyright (c) 2025 Oscar Pernia
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# This script builds MQTTy on macOS and assembles a double-clickable .app
# bundle that depends on the GTK runtime installed via Homebrew. The bundle
# is NOT portable across machines without the same Homebrew dependencies.
#
# Output:
#   build/install/bin/MQTTy   plain CLI binary
#   build/MQTTy.app           double-clickable bundle (unless --no-app)
#
# Tested on macOS 14+ with Homebrew on both Apple Silicon and Intel Macs.

set -e

USAGE="
Usage: $0 [options]

options:
    -p (default|development)  profile option passed to Meson (default: default)
    --no-app                  skip the .app bundle assembly step
    --no-deps                 skip the Homebrew dependency installation step
    -h | --help               show this help
"

PROFILE=default
BUILD_APP=1
INSTALL_DEPS=1

while [[ $# -gt 0 ]]; do
    case $1 in
        -p)
            shift
            PROFILE=$1
            if [[ $PROFILE != default && $PROFILE != development ]]; then
                echo "-p option must be one of 'default' or 'development'" 1>&2
                echo "$USAGE" 1>&2
                exit 1
            fi
            shift
            ;;
        --no-app)
            BUILD_APP=0
            shift
            ;;
        --no-deps)
            INSTALL_DEPS=0
            shift
            ;;
        -h|--help)
            echo "$USAGE"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" 1>&2
            echo "$USAGE" 1>&2
            exit 1
            ;;
    esac
done

# Sanity check: Homebrew is required for every GTK dependency
if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew is required. Install it from https://brew.sh first." 1>&2
    exit 1
fi

ROOT_DIR=$PWD
BREW_PREFIX=$(brew --prefix)

# Step 1: install build dependencies (idempotent: already-installed packages
# return success). 'gawk' is mandatory because data extraction in meson.build
# uses the gawk-only 'match($0, regex, arr)' 3-argument form, which BSD awk
# shipped with macOS does not support.
if [[ $INSTALL_DEPS -eq 1 ]]; then
    echo "==> Installing Homebrew dependencies..."
    brew install \
        meson \
        ninja \
        gtk4 \
        libadwaita \
        gtksourceview5 \
        openssl@3 \
        blueprint-compiler \
        dart-sass \
        adwaita-icon-theme \
        desktop-file-utils \
        gawk
fi

# Step 2: prepare environment so meson, pkg-config and the paho-mqtt-c
# cmake project find the right tools and headers.
export PATH="$BREW_PREFIX/opt/gawk/libexec/gnubin:$PATH"
export PKG_CONFIG_PATH="$BREW_PREFIX/opt/openssl@3/lib/pkgconfig:$PKG_CONFIG_PATH"
export OPENSSL_ROOT_DIR=$BREW_PREFIX/opt/openssl@3
export OPENSSL_DIR=$BREW_PREFIX/opt/openssl@3

# Step 3: configure with Meson. Install prefix points inside build/ so that
# the source tree stays clean and main.rs:45's relative path lookup works:
# current_exe().parent().parent() yields build/install/, which contains share/.
PREFIX=$ROOT_DIR/build/install

echo "==> Configuring Meson (profile=$PROFILE, prefix=$PREFIX)"
rm -rf build
meson setup build --prefix="$PREFIX" -Dprofile="$PROFILE"

# Step 4: compile and install. The paho-mqtt-c sub-build occasionally fails
# during the cmake step on a fresh checkout; rerunning ninja usually fixes it.
echo "==> Compiling (ninja -C build)"
ninja -C build

echo "==> Installing into $PREFIX"
ninja -C build install

VERSION=$(meson introspect build --projectinfo | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["version"])')

if [[ $BUILD_APP -eq 0 ]]; then
    echo "==> Skipping .app bundle (--no-app given)"
    echo "    Binary at: $PREFIX/bin/MQTTy"
    exit 0
fi

# Step 5: assemble the .app bundle. The layout is intentional:
# - MacOS/MQTTy        the unmodified executable
# - share/             sibling of MacOS/ so current_exe().parent().parent()/share
#                      resolves; this is non-standard (Apple expects Resources/)
#                      but avoids patching main.rs.
# - Resources/AppIcon.icns  generated from data/icons/<app_id>.svg
APP=$ROOT_DIR/build/MQTTy.app
ICONSET=$ROOT_DIR/build/AppIcon.iconset
ICNS=$ROOT_DIR/build/AppIcon.icns
SVG=$ROOT_DIR/data/icons/io.github.otaxhu.MQTTy.svg

echo "==> Generating AppIcon.icns from $SVG"
rm -rf "$ICONSET" "$ICNS" "$APP"
mkdir -p "$ICONSET"

# macOS .icns standard pairs: 1x + Retina @2x for each base size
for spec in "16:16x16" "32:16x16@2x" \
            "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" \
            "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
    size=${spec%%:*}
    name=${spec##*:}
    rsvg-convert -w "$size" -h "$size" "$SVG" -o "$ICONSET/icon_${name}.png"
done

iconutil -c icns "$ICONSET" -o "$ICNS"

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PREFIX/bin/MQTTy" "$APP/Contents/MacOS/MQTTy"
chmod +x "$APP/Contents/MacOS/MQTTy"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$PREFIX/share" "$APP/Contents/share"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>MQTTy</string>
	<key>CFBundleExecutable</key>
	<string>MQTTy</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.otaxhu.MQTTy</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MQTTy</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright (c) 2025 Oscar Pernia. Licensed under GPL-3.0-or-later.</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo ""
echo "Done. Bundle: $APP"
echo "  Launch with: open '$APP'"
echo ""
echo "Note: the bundle is NOT portable. It depends on Homebrew libraries at"
echo "      $BREW_PREFIX/opt/{gtk4,libadwaita,gtksourceview5,openssl@3,...}"
echo "      and will fail to launch on a Mac without those packages installed."
