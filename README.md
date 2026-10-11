# Hubble, the disk space telescope

A macOS app that finds what fills your disk, shows what grew since the last scan, and helps you clear out
build folders and caches (`target`, `node_modules`, DerivedData…).

- **Since last scan**: every scan is compared with the previous one, down to the folder where growth happened.
- **Rules**: mark folders as cleanup candidates (optionally only next to a file, e.g. `target` next to `Cargo.toml`) or ignore them.
- **Alerts**: free space, disk usage, and growth/size alerts per folder or rule category.
- **Background scans**: low-priority automatic scans, a menu bar item, and notifications.

## Install

Download [Hubble.zip](https://github.com/Dodecahedr0x/hubble/releases/latest/download/Hubble.zip) from the
latest release, unzip, and move Hubble.app to Applications. The app isn't notarized: on first launch, use
System Settings › Privacy & Security › Open Anyway.

## Build

```sh
swift test
./scripts/build-app.sh   # universal build/Hubble.app
```

Releases are built by GitHub Actions when a `v*` tag is pushed. The landing page in `site/` is deployed to
Render from `render.yaml`.
