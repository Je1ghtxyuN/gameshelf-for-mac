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

GameShelf brings your games into a native macOS library. Discover games in folders on your Mac, an external drive or a mounted NAS, or connect to an account-based shared library.

## Download

**[Download the latest release](https://github.com/Je1ghtxyuN/gameshelf-for-mac/releases/latest)** · macOS 15+ · Apple Silicon

Open the release DMG and drag **GameShelf.app** onto the **Applications** shortcut.

## Features

- **One library** — organize Windows, native macOS, visual novel, and 2D games with covers and custom collections.
- **Scan, then choose** — register library folders, discover complete games and add only the editions you select. Keep language launchers together and settings utilities out of the game list.
- **Optional shared libraries** — sign in to a self-hosted gateway and add authorized games. Resources stay on the server, with account-private writable views and local Wine runtimes.
- **Import in place** — keep game files on a local disk, an external drive, or a mounted NAS. Download a local copy when you want to play offline.
- **Visual novel imports** — identify QLIE, CatSystem2, KiriKiri and NScripter markers, keep configuration utilities out of the launcher list, and put translated launchers first.
- **Choose your entry point** — select the translated launcher when a game has several executables; GameShelf remembers the choice.
- **Flexible launch paths** — use Wine/Wineskin for Windows games, native macOS apps, Ren’Py engine adapters, or embedded WebKit for HTML games.
- **Playtime at a glance** — see total playtime below each cover, with recent sessions in **Properties → Play history**.
- **Make it yours** — rename library entries, add favorites, manage collections, and choose a local cover or search online.
- **Save management** — use engine-specific save migration, backups, and persistent game identities across folder reconnections.

## Getting started

On first launch, choose **Local use**, **Connect to a shared library**, or **Create a shared library**. Local use needs no account. A newly deployed gateway provides a private, one-use administrator setup file; open it in the creation flow to choose your own administrator credentials.

1. Click **Add library** and register a folder containing games. Local disks, external disks and mounted network folders work the same way.
2. Scan it, tick the games you want and choose a launch entry where needed. Nothing is added automatically. **File → Add game manually** remains available for special cases.
3. For Windows games, open **Settings** and select an existing **Wineskin `.app`** environment. Native Mac games use their own app; Ren’Py adapters use the matching engine version.
4. Click **Play** on the game card. Open **⋯ → Properties** to edit its name, launch settings, files, cover, or collections.

NAS games stay in their original directory. Keep the network share mounted while playing; reconnecting the same share preserves library entries. The **Download locally** action creates an offline copy.

For account-based sharing, open **Shared library**, load the server invitation file (or enter its address), then sign in. Select games from the authorized catalog; no NAS account is required. The gateway uses encrypted SMB3 and an independent writable workspace for each account and game. Shared games run from the network; the local-copy action applies to directly imported games.

Administrators can select **Add games** or **Server administration** in the client to scan sources, review save exclusions, publish selected games, create accounts and manage grants. The native panel uses the saved secure connection; a browser sign-in is optional.

See [server setup](Server/README.md) for accounts, scan/publish selection, access grants, certificates and save exclusions. Shared Windows games use private Wine user folders; managed native Ren’Py uses a private save directory. The verified RPG Maker MZ WebKit profile writes saves and settings to account-private network storage, with confirmation before exit. Other shared web and native engines need their own save adapter.

Shared-library sign-in lasts for the current app session. Passwords and login tokens are not saved to disk, and the client does not access macOS Keychain. Saved server addresses and account names remain available after relaunch.

In a connected library, the Account page can bind this Mac’s game metadata to your personal account. Names, collections, favorites, playtime and cover thumbnails sync separately from game files and saves. Shared-library default covers belong to published games; personal cover changes remain private.

Playtime is recorded while GameShelf is open, including background game time, and pauses when your Mac sleeps. Recording starts when this feature is enabled.

## Build from source

Install Apple Command Line Tools, Python 3.12+, Ruby, and Node.js 20+, then run:

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

Maintained by [Je1ghtxyuN](https://github.com/Je1ghtxyuN).

## License & credits

[MIT](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [Privacy](PRIVACY.md)

Visitor counter by [Moe Counter](https://github.com/journey-ad/Moe-Counter). Badges by [Shields.io](https://shields.io).
