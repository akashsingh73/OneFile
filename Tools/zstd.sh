# Compiles zstd's library (Vendor/zstd) into build/, for build.sh and test.sh, which source this.
# It's compiled once, on every core, and again only when something in Vendor/zstd changes.
#
#   zstd_library ARCH MIN_MACOS SDK
#
# sets ZSTD_INCLUDE (for swiftc's -I) and ZSTD_LIBRARY (the static library, to link).
zstd_library() {
  local arch="$1" min_macos="$2" sdk="$3"
  local dir="build/zstd/$arch-macos$min_macos"
  ZSTD_INCLUDE="Vendor/zstd"
  ZSTD_LIBRARY="$dir/libzstd.a"
  if [[ -f "$ZSTD_LIBRARY" && -z "$(find Vendor/zstd Tools/zstd.sh -newer "$ZSTD_LIBRARY" -print -quit)" ]]; then
    return 0
  fi
  echo "Compiling zstd…"
  rm -rf "$dir"
  mkdir -p "$dir"
  local source object failed=0
  local pids=()
  # Without the decoders for zstd's pre-1.0 formats (not included), and with xxHash's names
  # prefixed, as zstd's own build does.
  for source in Vendor/zstd/lib/common/*.c Vendor/zstd/lib/compress/*.c Vendor/zstd/lib/decompress/*.c \
                Vendor/zstd/lib/decompress/*.S; do
    object="$dir/$(basename "$(dirname "$source")")-$(basename "${source%.*}").o"
    xcrun clang -c -O3 -target "$arch-apple-macos$min_macos" -isysroot "$sdk" \
      -DZSTD_LEGACY_SUPPORT=0 -DXXH_NAMESPACE=ZSTD_ \
      -o "$object" "$source" 2>>"$dir/compile.log" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  if [[ $failed -ne 0 ]] || ! xcrun libtool -static -no_warning_for_no_symbols -o "$ZSTD_LIBRARY" "$dir"/*.o \
       2>>"$dir/compile.log"; then
    cat "$dir/compile.log"
    echo
    echo "zstd didn't compile (full log: $dir/compile.log)."
    rm -f "$ZSTD_LIBRARY"
    return 1
  fi
}
