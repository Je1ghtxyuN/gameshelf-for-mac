# Wine window and cursor coordinates

GameShelf launches Wine games in the game's own window. This policy applies to
existing libraries and new imports, regardless of the selected engine.

The default launch does not use `explorer /desktop=…` and does not run the
GameShelf window helper to move the window after creation. Older saved
`windowSize` values are ignored by this launch path. The game remains responsible
for its window, fullscreen mode and cursor coordinates.

## Verified case

My Expedition showed a fixed cursor movement rectangle after its window moved.
Launching the same game directly, without the virtual desktop and window mover,
restored the cursor range in the user's test. This is the baseline for games
with the same symptom. It removes two coordinate-mapping layers; an engine's own
cursor confinement or a Wine driver defect may still need a separate fix.

PURE ONYX keeps its explicit windowed/fullscreen preference. Its keyboard failure
after switching applications is a separate input-focus issue, not a cursor fix.

## Regression checks

`Tests/WineWindowPolicyTests.swift` checks direct launches for Windows, Unity and
RPG Maker profiles with legacy desktop sizes, preservation of the executable,
working directory and environment, and PURE ONYX's fullscreen option. Launch
construction does not mutate library metadata, game files or save locations.

For a manual check, launch one game, move its window, test all four content
corners, then switch to another application and back. Test fullscreen separately
if the game supports it. Exit the test game before testing another profile.
