# Cobalt Faders artwork

`AppIcon.png` is the production asset for the Cobalt Faders icon concept.
It was generated with the built-in Image Generation tool on 6 October 2026.
The original review board is a local design artifact and is not included in Git.

Final generation brief: isolate the approved cobalt-to-indigo rounded-square
icon on transparency; preserve three white vertical faders, with the left thumb
low, middle thumb high and right thumb midway; keep restrained glass highlights,
equal transparent margins, generous glyph inset, and no text or surrounding UI.

`scripts/make-icon.swift` resizes the source into standard and Retina ICNS
representations. `MenuBarIcon.png` is a separately isolated filled-fader silhouette from the same
approved board, generated with the built-in Image Generation tool. Its final
brief specified a solid black three-fader glyph on transparency, with capsule
thumbs (left low, middle high, right midway), clean edges and no other marks.
The build exports 18-point PNG representations at 1×/2×/3×. AppKit treats these
as template images, inheriting the menu bar's light/dark/selected color. The stock
SF Symbol is only a fallback if a development bundle lacks the assets.
