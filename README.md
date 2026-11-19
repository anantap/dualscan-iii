# Dual Scan III

The Dual III edition of Dual Scan: a Mac app for the Minolta Dimage Scan
Dual III, to replace VueScan. It has its own repository, apart from Dual Scan
for the Dual IV (`anantap/dualscan`). They are separate apps (their own name,
bundle ID, settings, scans folder and updates), so both can sit on one Mac
without getting in each other's way.

Download: https://github.com/anantap/dualscan-iii/releases/latest
Scan once at full quality, make a base edit live (no rescans), then export
a JPEG, a 16-bit base TIFF or the raw scan, or open the scans in another app.

## How it talks to the scanner

No reverse engineering needed: the open-source SANE project added Dual IV
support to its `avision` driver in November 2026. It is not in a SANE release
yet, so `scripts/build-sane.sh` builds it from a pinned master commit into
`sane/`: only the avision backend, as one static library, with a static libusb.
Both are linked into the app, so `Dual Scan III.app` needs nothing outside itself.

The Dual III has been in that driver for years. The app asks the driver what
the connected model can do and shows only that: on the Dual III that is 705,
1410 or 2820 dpi, with no auto exposure, autofocus or per-channel exposure
(the scanner handles exposure itself). A small patch in `scripts/sane-patches/`
lets the driver report an empty holder and eject on the Dual III too, as it
already does on the Dual IV.

Needs `brew install autoconf autoconf-archive automake libtool pkgconf libusb gettext xcodegen`.

## Building the app

```
app/build.sh            # → app/build/Dual Scan III.app (builds SANE first if needed)
app/build.sh --install  # … and copies it to /Applications
```

## Updates

Like Roll Converter: every push to `main` that touches the app makes GitHub
(`.github/workflows/dual-iii-app.yml`) build it, run the self-test and publish
it as the latest release, `build-<n>` with `Dual-Scan-III.zip`. The app looks for a
newer build when it starts (and under Dual Scan › Check for Updates…),
downloads it in the background and puts it in place when you restart or quit.
It won't restart while the scanner or an export is busy. A local build is
build 1 and never looks for updates.

## Trying it without the scanner

The app has a simulated Dual III that produces fake orange negatives:

- on the first screen, click "No scanner here? Use a simulated one", or
- start it with `--simulate`.

`--selftest <folder>` runs the whole flow on the simulator, saves pictures of
the window and the exported files there, and quits.

## Where files go

- Raw scans are kept in `~/Pictures/Dual Scan III/<date> <roll>/Raw`.
- Exports go to that roll folder unless you choose another one when exporting.

## Folders

- `app/` — the SwiftUI app (`project.yml` for XcodeGen; `scripts/make-icon.swift` draws the icon)
- `sane-backends/` — SANE source, `sane/` — the built driver
- `reference/` — the driver source and manual, for reading
