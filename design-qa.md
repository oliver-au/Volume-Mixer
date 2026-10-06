# Native interface QA — 1.2.0

Result: the icon and menu-panel refresh passed its visual and interface review.
This does not establish the complete audio/device acceptance matrix in
`VERIFICATION.md`. Review screenshots and diagnostic logs are local-only artifacts.

## Design and inspection

- The approved Cobalt Faders concept is represented by the original PNG artwork
  in `Resources/Artwork`. The app icon uses three filled white vertical faders
  on a cobalt/indigo rounded square. A separate monochrome fader template follows
  native menu-bar colors. Builds generate standard/Retina ICNS and 1×/2×/3× menu
  representations; Finder displayed the packaged icon correctly.
- Apple's Battery menu served as the layout/material reference. The implemented
  panel uses native glass, an arrowless 20-point corner radius, 16-point insets,
  system typography, subtle separators and 24-point app icons.
- The panel is 340 points wide and anchors four points below the status item.
  Measured content height controls scrolling while the header and footer stay
  visible. A fallback handles temporarily invalid status-item coordinates.
- System label and secondary colors follow light/dark appearance. Error, mute
  and pause states also use explicit text; they do not rely on color alone.
- Long app names truncate visually while help and accessibility retain their
  complete names. The native slider takes keyboard focus on click; arrows adjust
  by one percent and Shift–arrow by ten percent.

## Interaction checks

The isolated preview uses fake audio sessions and memory-backed settings.
It does not enumerate hardware or change system preferences.

- Light/dark, normal, muted, paused, error, empty and onboarding states fit.
- Twelve rows scroll with persistent header/footer; error details remain reachable.
- Mute preserved a 52% level; moving the slider to 60% unmuted it.
- Keyboard changes advanced one app from 50% to 51% to 52% while another stayed
  at 37%. Output selection changed only the selected fixture's route.
- Pause disabled controls and exposed Resume control with a status banner.
- Enabling the onboarding preview collapsed its explanation and resized the panel.
- Native accessibility exposed names, percentages and muted states.
- Escape and outside clicks dismissed the panel. Two inspection calls timed out
  during menu tracking; Escape restored inspection and the menu worked on retry.

Initial clipping, keyboard-focus and hollow-symbol issues were corrected before
packaging. No open visual defect was found in the checked states.

## Limits

Full VoiceOver navigation, physical multi-display transitions, auto-hidden menu
bars and accessibility appearance toggles were not exercised. Live Bluetooth
playback was not repeated for the interface refresh. No macOS settings changes
or administrator rights were used for the preview checks.
