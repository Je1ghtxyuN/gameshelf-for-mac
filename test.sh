#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
for tool in swiftc python3 ruby node; do command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }; done
node_bin="$(command -v node)"
mkdir -p build/module-cache
run_swift() {
 local name="$1"; shift
 local sources=("$@")
 case " $* " in *" Sources/Core.swift "*) sources+=(Sources/VisualNovelProbe.swift);; esac
 swiftc -swift-version 5 -module-cache-path build/module-cache "${sources[@]}" "Tests/${name}Tests.swift" -o "build/${name}Tests"
 "build/${name}Tests"
}
for name in Core Storage Runtime Safety NativeEngine RTP RPGDictionary GameResourceServer; do
 run_swift "$name" Sources/Core.swift Sources/Runtime.swift Sources/NativeEngines.swift Sources/RTP.swift Sources/RPGDictionary.swift Sources/GameResourceServer.swift
done
run_swift CoverArt Sources/Core.swift Sources/CoverArt.swift
for name in PreparationTask ImportProgress Collection Rename; do run_swift "$name" Sources/Core.swift; done
run_swift MZSaveArchive Sources/Core.swift Sources/MZSaveMigration.swift
run_swift NativeAppCache Sources/Core.swift Sources/NativeAppCache.swift
run_swift NativeGameSaves Sources/Core.swift Sources/MZSaveMigration.swift Sources/NativeGameSaves.swift
run_swift UnityCursorAdapter Sources/Core.swift Sources/UnityCursorAdapter.swift
run_swift SettingsModel Sources/SettingsModel.swift
run_swift PlaytimeStore Sources/PlaytimeStore.swift
run_swift PlaytimeRecorder Sources/PlaytimeStore.swift Sources/PlaytimeRecorder.swift
"$node_bin" --test Tests/MZSaveMigrationTests.js Tests/MZSaveBootstrapTests.js
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p test_renpy_save_migration.py -q

run_swift VisualNovelProbe Sources/VisualNovelProbe.swift
run_swift VisualNovelImport Sources/Core.swift
