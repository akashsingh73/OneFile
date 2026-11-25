# zstd

The zstd library, for OneFile's Efficient method (`.tar.zst`): **zstd 1.5.7**, by Meta, under the
BSD license in [LICENSE](LICENSE).

- **From** `https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz` (the project now
  lives at github.com/meta/zstd), SHA-256
  `37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3`, the checksum Homebrew's zstd
  formula records for that release.
- **Copied unchanged:** `lib/zstd.h`, `lib/zstd_errors.h`, `lib/common`, `lib/compress` and
  `lib/decompress`. Left out: the dictionary builder, the decoders for zstd's old pre-1.0 formats,
  the `zstd` program, the tests and the docs.
- **OneFile's own:** `module.modulemap` (so Swift can `import CZstd`) and this file.
- **Built** by `Tools/zstd.sh`, from `build.sh` and `test.sh`, into a static library in `build/`:
  once, and again only when something here changes. `build.sh` also puts `LICENSE` inside the app
  (`Contents/Resources/Licenses/zstd-LICENSE.txt`), as the BSD license asks of anything built from
  this code.

To update it: download a newer release, check its SHA-256, and replace `lib/` and `LICENSE`.
