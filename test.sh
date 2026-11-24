#!/bin/bash
# Tests OneFile using only Apple's free Command Line Tools (no Xcode).
#
#   bash test.sh                        check Swift 6 readiness, then run the tests
#   bash test.sh --pack FOLDER FILE [plain|gzip|xz]   pack a folder of your own and say how long it took
#   bash test.sh --estimate FOLDER                    each method's estimated size and time for a folder
#   bash test.sh --unpack FILE FOLDER                 unpack a .tar, .tar.gz or .tar.xz and say how long it took
#   bash test.sh --inspect FILE                       what's inside one, without unpacking it
#   bash test.sh --copy FOLDER DESTINATION            copy a folder into another (on another drive, say), timed
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler isn't installed yet. Install Apple's free Command Line Tools:"
  echo "    xcode-select --install"
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="$(uname -m)-apple-macos14.0"
OUT="build/tests"
mkdir -p "$OUT"

# The app is built in the Swift 5 language mode; this keeps it ready for Swift 6's stricter
# concurrency checks (any warning there fails the run).
if [[ "${1:-}" != --* ]]; then
  echo "Checking that OneFile compiles cleanly in the Swift 6 language mode…"
  if ! xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -wmo \
    -sdk "$SDK" -target "$TARGET" -module-name OneFile \
    -o "$OUT/OneFile-swift6" OneFile/*.swift > "$OUT/swift6.log" 2>&1; then
    cat "$OUT/swift6.log"
    echo
    echo "OneFile doesn't compile cleanly in Swift 6 mode (full log: $OUT/swift6.log)."
    exit 1
  fi
fi

# Everything except the app's entry point, plus the tests (which have their own).
SOURCES=()
for file in OneFile/*.swift; do
  [[ "$file" == */OneFileApp.swift ]] || SOURCES+=("$file")
done

echo "Compiling the tests…"
if ! xcrun swiftc -O -swift-version 5 -parse-as-library \
  -sdk "$SDK" -target "$TARGET" -module-name OneFile \
  -o "$OUT/OneFileTests" "${SOURCES[@]}" Tests/*.swift > "$OUT/compile.log" 2>&1; then
  cat "$OUT/compile.log"
  exit 1
fi

# Two disk images for the copying tests to copy to: another APFS drive, and an exFAT one (as
# most USB drives come). Hidden from Finder, and gone when the tests end. (An exFAT drive's name
# is at most 11 characters: hdiutil says "Operation not permitted" for a longer one.)
if [[ "${1:-}" != --* ]]; then
  IMAGES="$OUT/images"
  detach_images() {
    for mount in "$IMAGES"/mnt-*; do
      [[ -d "$mount" ]] && hdiutil detach -quiet -force "$mount" >/dev/null 2>&1 || true
    done
    rm -f "$IMAGES"/disk-*.sparseimage
  }
  detach_images
  rm -rf "$IMAGES"
  mkdir -p "$IMAGES"
  trap detach_images EXIT
  for format in APFS ExFAT; do
    mkdir -p "$IMAGES/mnt-$format"
    if hdiutil create -quiet -size 400m -fs "$format" -volname "OF Test" -type SPARSE \
         "$IMAGES/disk-$format" >/dev/null 2>&1 \
       && hdiutil attach -quiet -nobrowse -mountpoint "$IMAGES/mnt-$format" "$IMAGES/disk-$format.sparseimage" >/dev/null 2>&1; then
      export "ONEFILE_TEST_$format=$IMAGES/mnt-$format"
    fi
  done
fi

"$OUT/OneFileTests" "$@"
