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
 case " $* " in *" Sources/SharedLibrary.swift "*) sources+=(Sources/PinnedHTTP.swift);; esac
 swiftc -swift-version 5 -module-cache-path build/module-cache "${sources[@]}" "Tests/${name}Tests.swift" -o "build/${name}Tests"
 "build/${name}Tests"
}
for name in Core Storage Runtime Safety NativeEngine RTP RPGDictionary GameResourceServer; do
 run_swift "$name" Sources/Core.swift Sources/Runtime.swift Sources/NativeEngines.swift Sources/RTP.swift Sources/RPGDictionary.swift Sources/GameResourceServer.swift
done
run_swift ManagedWine Sources/ManagedWine.swift
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p test_managed_wine_install.py -q
run_swift RosettaPreparation Sources/Core.swift Sources/RosettaPreparation.swift
run_swift CoverArt Sources/Core.swift Sources/CoverArt.swift
run_swift GameMetadataCatalog Sources/Core.swift Sources/CoverArt.swift Sources/GameMetadataCatalog.swift
run_swift VerifiedGameMetadata Sources/Core.swift Sources/CoverArt.swift Sources/GameMetadataCatalog.swift Sources/VerifiedGameMetadata.swift
for name in PreparationTask ImportProgress Collection Rename; do run_swift "$name" Sources/Core.swift; done
run_swift MZSaveArchive Sources/Core.swift Sources/MZSaveMigration.swift
run_swift NativeAppCache Sources/Core.swift Sources/NativeAppCache.swift Sources/NativeAppIdentity.swift Sources/NativeRenpyBootstrap.swift -framework AppKit
run_swift NativeAppIdentity Sources/Core.swift Sources/NativeAppCache.swift Sources/NativeAppIdentity.swift Sources/NativeRenpyBootstrap.swift -framework AppKit
run_swift NativeRenpyBootstrap Sources/Core.swift Sources/NativeAppCache.swift Sources/NativeAppIdentity.swift Sources/NativeRenpyBootstrap.swift -framework AppKit
run_swift NativeGameSaves Sources/Core.swift Sources/MZSaveMigration.swift Sources/NativeGameSaves.swift
run_swift UnityCursorAdapter Sources/Core.swift Sources/UnityCursorAdapter.swift
run_swift SettingsModel Sources/SettingsModel.swift
run_swift NativeVolumePolicy Sources/NativeVolumePolicy.swift
run_swift LibraryGridGeometry Sources/LibraryGrid.swift -framework AppKit
run_swift PlaytimeStore Sources/PlaytimeStore.swift
run_swift PlaytimeRecorder Sources/PlaytimeStore.swift Sources/PlaytimeRecorder.swift
"$node_bin" --test Tests/MZSaveMigrationTests.js Tests/MZSaveBootstrapTests.js Tests/SharedWebStorageTests.js
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p test_renpy_save_migration.py -q

run_swift VisualNovelProbe Sources/VisualNovelProbe.swift
run_swift VisualNovelImport Sources/Core.swift
run_swift LibraryDiscovery Sources/Core.swift Sources/LibraryDiscovery.swift
run_swift DiscoveryPresentation Sources/Core.swift Sources/DiscoveryPresentation.swift
run_swift SharedScanSelection Sources/Core.swift Sources/SharedScanSelection.swift
run_swift DiscoverySelectionPolicy Sources/Core.swift Sources/LibraryDiscovery.swift Sources/DiscoverySelectionPolicy.swift
run_swift SharedPublishSelection Sources/Core.swift Sources/LibraryDiscovery.swift Sources/SharedScanSelection.swift Sources/SharedPublishSelection.swift
run_swift SharedEntryFingerprint Sources/Core.swift Sources/SharedEntryFingerprint.swift
run_swift SharedPublicationBatch Sources/SharedPublicationBatch.swift
run_swift SharedPublicationError Sources/Core.swift Sources/SharedLibrary.swift Sources/SharedPublicationError.swift
run_swift WineWindowPolicy Sources/Core.swift Sources/Runtime.swift Sources/WineWindowPolicy.swift
clang -Wall -Wextra -Werror Tests/WineWindowGeometryTests.c -o build/WineWindowGeometryTests
build/WineWindowGeometryTests
run_swift DiscoveryBinding Sources/Core.swift Sources/LibraryDiscovery.swift Sources/DiscoveryBinding.swift
run_swift NetworkLibraryMount Sources/NetworkLibraryMount.swift
run_swift SharedSessionTokens Sources/SharedSessionTokens.swift
run_swift SharedLibrary Sources/Core.swift Sources/SharedLibrary.swift
run_swift SharedInvitation Sources/Core.swift Sources/SharedLibrary.swift
run_swift SharedNavigation Sources/Core.swift Sources/SharedLibrary.swift Sources/SharedNavigation.swift
run_swift SharedAdministration Sources/Core.swift Sources/SharedAdministration.swift
run_swift SharedProfile Sources/Core.swift Sources/SharedProfile.swift
run_swift SharedWineRuntime Sources/Core.swift Sources/Runtime.swift Sources/SharedProfile.swift Sources/SharedWineBootstrap.swift
PYTHONPATH="$PWD/Server" PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Server/tests -p 'test_*.py' -q

run_swift SharedWebSaveStore Sources/SharedWebSaveStore.swift
run_swift SharedWebKitIntegration Sources/Core.swift Sources/GameResourceServer.swift Sources/SharedWebSaveStore.swift Sources/SharedWebKit.swift

run_swift PersonalLibrary Sources/Core.swift Sources/SharedLibrary.swift Sources/PersonalLibrary.swift
run_swift PersonalLibraryMedia Sources/Core.swift Sources/SharedLibrary.swift Sources/PersonalLibraryMedia.swift
run_swift Onboarding Sources/Core.swift Sources/SharedLibrary.swift Sources/Onboarding.swift
"$node_bin" --test Server/tests/test_admin_ui.js

run_swift PinnedHTTP Sources/PinnedHTTP.swift
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p test_shared_https_bundle.py -q
