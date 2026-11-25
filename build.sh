#!/bin/bash
# Builds OneFile.app using only Apple's free Command Line Tools.
# No Xcode, no Apple ID, no developer account.
#
#   bash build.sh                   build into ./build/OneFile.app (with the onefile command inside)
#   bash build.sh --install         build, then copy to /Applications
#   bash build.sh --install --open  build, install, and launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="OneFile"
APP="build/$APP_NAME.app"
# The version is kept in one place, for the app and the onefile command alike.
VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' OneFile/Version.swift)"
BUILD_NUMBER="$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' OneFile/Version.swift)"
MIN_MACOS="14.0"
ARCH="$(uname -m)"

INSTALL=0
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --open) OPEN=1 ;;
    *) echo "Unknown option: $arg (use --install and/or --open)"; exit 1 ;;
  esac
done

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler isn't installed yet. Install Apple's free Command Line Tools:"
  echo "    xcode-select --install"
  echo "then run this script again."
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

# zstd's library, compiled from its own source in Vendor/zstd (see the README there).
source Tools/zstd.sh
zstd_library "$ARCH" "$MIN_MACOS" "$SDK"

echo "Compiling $APP_NAME $VERSION for $ARCH (macOS $MIN_MACOS or later)…"
if ! xcrun swiftc \
  -O -wmo -swift-version 5 -parse-as-library \
  -sdk "$SDK" \
  -target "$ARCH-apple-macos$MIN_MACOS" \
  -module-name "$APP_NAME" \
  -I "$ZSTD_INCLUDE" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  OneFile/*.swift "$ZSTD_LIBRARY" 2>&1 | tee build/compile.log; then
  echo
  echo "The build stopped. The full list of errors is in build/compile.log."
  exit 1
fi

# The onefile command: the same engine, without the windows (every file that doesn't import
# SwiftUI or AppKit), plus CLI/main.swift.
ENGINE=()
for file in OneFile/*.swift; do
  /usr/bin/grep -q -E '^import (SwiftUI|AppKit)' "$file" || ENGINE+=("$file")
done
echo "Compiling the onefile command…"
if ! xcrun swiftc \
  -O -wmo -swift-version 5 \
  -sdk "$SDK" \
  -target "$ARCH-apple-macos$MIN_MACOS" \
  -module-name "$APP_NAME" \
  -I "$ZSTD_INCLUDE" \
  -o "$APP/Contents/Helpers/onefile" \
  "${ENGINE[@]}" CLI/main.swift "$ZSTD_LIBRARY" 2>&1 | tee build/compile-cli.log; then
  echo
  echo "The build stopped. The full list of errors is in build/compile-cli.log."
  exit 1
fi
codesign --force --sign - "$APP/Contents/Helpers/onefile"

# The app icon (drawn by Tools/make-icon.swift).
if [[ -f OneFile/AppIcon.icns ]]; then
  cp OneFile/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <!-- Folders and tar files can be dropped on OneFile's icon. Folders rank None (it never becomes
         the app that opens folders), tar files Alternate (it's in Open With, but Archive Utility stays
         the default). -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Tar Archive</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>org.gnu.gnu-zip-tar-archive</string>
                <string>org.tukaani.xz-archive</string>
                <string>org.tukaani.tar-xz-archive</string>
                <string>com.facebook.zstd-archive</string>
            </array>
        </dict>
    </array>
    <!-- macOS has no type for zstd files (.tar.zst, .tzst), so it's declared here: imported, as
         OneFile doesn't own the format. -->
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.facebook.zstd-archive</string>
            <key>UTTypeDescription</key><string>Zstandard archive</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.archive</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key><array><string>zst</string><string>tzst</string></array>
                <key>public.mime-type</key><array><string>application/zstd</string></array>
            </dict>
        </dict>
    </array>
    <!-- Finder's Services menu: Control-click a folder or a tar file. -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Pack with OneFile</string></dict>
            <key>NSMessage</key><string>packWithOneFile</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.folder</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Send to a Mac with OneFile</string></dict>
            <key>NSMessage</key><string>sendWithOneFile</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.folder</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Unpack with OneFile</string></dict>
            <key>NSMessage</key><string>unpackWithOneFile</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>org.gnu.gnu-zip-tar-archive</string>
                <string>org.tukaani.xz-archive</string>
                <string>org.tukaani.tar-xz-archive</string>
                <string>com.facebook.zstd-archive</string>
            </array>
        </dict>
    </array>
    <!-- Send and Receive: finding other Macs running OneFile, and connecting to them. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>OneFile link</string>
            <key>CFBundleURLSchemes</key><array><string>onefile</string></array>
        </dict>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>OneFile finds other Macs running OneFile on your network, so you can send folders between them.</string>
    <key>NSBonjourServices</key>
    <array><string>_onefile._tcp</string></array>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.onefile.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# An ad-hoc signature: no certificate or account needed to run it on this Mac.
codesign --force --sign - "$APP"
echo "Built $APP"

TARGET="$APP"
if [[ $INSTALL -eq 1 ]]; then
  # Replacing the app while it runs can crash the running copy, so quit it first.
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Quitting the running $APP_NAME…"
    pkill -x "$APP_NAME" || true
    sleep 1
  fi
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  TARGET="/Applications/$APP_NAME.app"
  echo "Installed $TARGET"
fi

if [[ $OPEN -eq 1 ]]; then
  open "$TARGET"
fi
