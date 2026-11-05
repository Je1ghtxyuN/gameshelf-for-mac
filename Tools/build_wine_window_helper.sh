#!/bin/bash
# No downloads or system installation. Pass an already verified Zig executable.
# Usage: bash Tools/build_wine_window_helper.sh /absolute/path/to/zig [--fixtures]
set -euo pipefail
cd "$(dirname "$0")/.."
zig_exe="${1:?Pass the verified Zig executable}"
case "$zig_exe" in /*) ;; *) echo 'Zig path must be absolute' >&2; exit 64;; esac
[[ -x "$zig_exe" ]] || { echo 'Zig executable unavailable' >&2; exit 64; }
[[ $# -le 2 && ( $# -eq 1 || "$2" == --fixtures ) ]] || exit 64
mkdir -p build/wine-window-toolchain/cache build/wine-window-toolchain/local-cache
export ZIG_GLOBAL_CACHE_DIR="$PWD/build/wine-window-toolchain/cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/build/wine-window-toolchain/local-cache"
stage="$(mktemp -d "$PWD/build/.WineWindowBuild.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
"$zig_exe" cc -target x86_64-windows-gnu -municode -O2 -Wall -Wextra -Werror Tools/wine_window_launcher.c -luser32 -lshell32 -Wl,--subsystem,windows -o "$stage/GameShelfWineWindow.exe"
if [[ "${2:-}" == --fixtures ]]; then
 for target in x86_64 x86; do
  name=WineWindowFixture; [[ "$target" == x86 ]] && name=WineWindowFixture32
  "$zig_exe" cc -target "$target-windows-gnu" -municode -O2 -Wall -Wextra -Werror Tests/WineWindowFixture.c -luser32 -o "$stage/$name.exe"
 done
fi
for output in "$stage/"*.exe; do mv "$output" "build/$(basename "$output")"; done
printf '%s\n' 'Built build/GameShelfWineWindow.exe from local sources'
