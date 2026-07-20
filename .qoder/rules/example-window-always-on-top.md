---
trigger: always_on
description: The example (Windows encoder) window must always stay on top / frontmost, in every mode.
---

# Example window must stay always-on-top (frontmost)

The `example/` Windows encoder app MUST keep its main window **topmost /
frontmost at all times**, in BOTH the windowed layout and the cover-taskbar
(full-screen) layout.

## Why
The app displays animated cimbar barcodes that are meant to be filmed/scanned
by the decoder. If the window drops behind other windows or the taskbar, the
barcode is occluded and decoding fails. This behavior has regressed several
times, so it is a hard invariant.

## Requirements
- After ANY window operation (startup, resize, mode toggle, capture/restore),
  the window must end up topmost. Call `windowManager.setAlwaysOnTop(true)`
  **last** (after `setBounds`) — see `coverTaskbar()` / `restoreWindowed()` in
  `example/lib/core/window_display.dart`.
- Re-assert topmost whenever the window loses focus. This is enforced by
  `onWindowBlur()` (a `WindowListener`) in `example/lib/encoder_page.dart`.
- Do NOT clear always-on-top except transiently inside the screenshot
  region-capture flow (`example/lib/core/window_ctrl.dart`), which MUST restore
  it afterwards.

## Do not regress
Any change to window positioning/sizing/visibility must preserve the
always-on-top invariant. If you add a new window state, re-assert
`setAlwaysOnTop(true)` at the end of that transition.
