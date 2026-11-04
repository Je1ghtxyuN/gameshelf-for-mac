<p align="center">
  <img src="https://count.getloli.com/@gameshelf-for-mac?theme=moebooru&amp;padding=7&amp;darkmode=auto" alt="GameShelf visitors" width="460" />
</p>

<h1 align="center">GameShelf for Mac</h1>

<p align="center">Your Windows and Mac games, together on macOS.</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
  <a href="https://github.com/Je1ghtxyuN/gameshelf-for-mac/releases/latest"><img src="https://img.shields.io/github/v/release/Je1ghtxyuN/gameshelf-for-mac?style=flat-square" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square&amp;logo=apple" alt="macOS 15+" />
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-7C3AED?style=flat-square" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Swift-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white" alt="Swift" />
</p>

<p align="center"><strong>English</strong> · <a href="README_zh-CN.md">简体中文</a></p>

GameShelf brings your games into a native macOS library. Import a folder from your Mac, an external drive, or a NAS, then launch it from one place.

## Download

**[Download the latest release](https://github.com/Je1ghtxyuN/gameshelf-for-mac/releases/latest)** · macOS 15+ · Apple Silicon

Open `GameShelf-v1.0.0-macOS-arm64.dmg` and drag **GameShelf.app** onto the **Applications** shortcut. A ZIP download is also available.

## Features

- **One library** — organize Windows, native macOS, visual novel, and 2D games with covers and custom collections.
- **Import in place** — keep game files on a local disk, an external drive, or a mounted NAS. Download a local copy when you want to play offline.
- **Choose your entry point** — select the translated launcher when a game has several executables; GameShelf remembers the choice.
- **Flexible launch paths** — use Wine/Wineskin for Windows games, native macOS apps, Ren’Py engine adapters, or embedded WebKit for HTML games.
- **Playtime at a glance** — see total playtime below each cover, with recent sessions in **Properties → Play history**.
- **Make it yours** — rename library entries, add favorites, manage collections, and choose a local cover or search online.
- **Save management** — use engine-specific save migration, backups, and persistent game identities across folder reconnections.

## Getting started

1. Click **Import game** and choose the game's root folder.
2. If several launchers are found, choose the one you use, such as the translated version.
3. For Windows games, open **Settings** and select an existing **Wineskin `.app`** environment. Native Mac games use their own app; Ren’Py adapters use the matching engine version.
4. Click **Play** on the game card. Open **⋯ → Properties** to edit its name, launch settings, files, cover, or collections.

NAS games stay in their original directory. Keep the network share mounted while playing; reconnecting the same share preserves library entries. The **Download locally** action creates an offline copy.

Playtime is recorded while GameShelf is open, including background game time, and pauses when your Mac sleeps. Recording starts when this feature is enabled.

## Build from source

Install Apple Command Line Tools, Python 3.10+, Ruby, and Node.js 20+, then run:

```sh
./build.sh
./test.sh
./package-dmg.sh
```

The app is built at `dist/GameShelf.app` with a local ad-hoc signature. `ARCH=arm64 ./build.sh` explicitly selects Apple Silicon; `ARCH=x86_64` is also available for development builds. Tests use generated fixtures and temporary directories.

For the standalone Ren’Py save migration tool:

```sh
python3 Tools/migrate_renpy_saves.py --help
```

## License & credits

[MIT](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [Privacy](PRIVACY.md)

Visitor counter by [Moe Counter](https://github.com/journey-ad/Moe-Counter). Badges by [Shields.io](https://shields.io).
