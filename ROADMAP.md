# Roadmap

What's planned next.

## Send to and from phones, tablets and other computers

Android phones, iPads and iPhones, Windows and Linux laptops: anything with a web browser on the same
network, with nothing to install on it.

- **Receive on the Mac.** The Receive screen gets an "Any device" option that shows a QR code (and a
  short address to type). Scanning it opens a page that OneFile itself serves. Pick files or a folder
  there; the Mac shows what's coming and from which device, and nothing arrives until you accept. It
  goes into a new "NAME (receiving)" folder, with the same protections as unpacking (no `..` paths,
  nothing written through a link, every file opened with `O_NOFOLLOW_ANY`), and gets its name when
  it's complete.
- **Send from the Mac.** Send gets an "Any device" option: the QR code opens a page with a Download
  button. The folder downloads as a `.zip` that's made as it downloads, with no file in between. It's
  stored uncompressed so it goes as fast as the network, with its exact size worked out first so the
  browser shows real progress, ZIP64 for big folders, and UTF-8 names.
- **Built in.** A small HTTP server on `NWListener` (port 52526 if it's free) and one page that works
  well on a phone, both inside the app. Each session's address carries a random token, so only
  whoever scans the code can connect, and the server stops when you leave the screen.
- **Honest about security.** A browser can't do the code-confirmed, end-to-end encryption that Mac to
  Mac Send uses, so the page and the Mac both say it isn't encrypted on the network: use it on networks
  you trust.
- **Tests.** Downloads checked with `unzip -t`, Python's `zipfile` and `ditto`; uploads made with
  `curl` and `URLSession`; the page itself tried in a browser against the app.

## Also noted

- **Hard drives.** Copying from a spinning hard drive reads 4 files at a time, in the order they are
  on the disk. The tests force that path, but it still needs measuring and tuning on a real hard
  drive.
- **"Waiting for the drive."** When a drive is too busy to answer (another app deleting or uploading
  on it, Spotlight indexing it), packing and copying can look stuck. The progress should say it's
  waiting for the drive.
- **Google Drive without a client of your own.** Signing in to Google Drive needs a Google Cloud
  client; OneFile can't ship one in a public repository. A verified client would let anyone sign in
  with a click.

## Done

- **Unpack other tools' files on every core**: `.tar.xz` from `xz` (its blocks, one to a core), and
  `.tar.gz` from `tar` and `gzip` (one long stream, cut into spans and pieced back together).
- **zstd**: a fourth method, Efficient (`.tar.zst`): smaller than Balanced and quicker, on every
  core, from zstd's own library.
- **Command line**: the `onefile` command, for everything the app does.
- **Back up when a drive is plugged in**, even when OneFile isn't open.
- **The cloud**: pack to S3-compatible storage and Google Drive as it packs; unpack, look inside and
  take files out straight from the cloud or any link; share links.
- **OneFile's index**: look inside at once, take out one file, check every file's SHA-256.
- **Lock with a password** (age), **split into parts**, **leave out what Git ignores**.
- **Verify copies, mirror, compare folders.**
- **Drives**: speed with many small files, deleting fast.
- **Work gently, pause on battery**, and links for Shortcuts (`onefile://`).
