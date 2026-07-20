import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Default windowed size when the app is NOT covering the taskbar.
const Size kDefaultWindowedSize = Size(1400, 1100);

/// Make the main window cover the entire monitor — including the Windows
/// taskbar — WITHOUT entering fullscreen mode.
///
/// The window is borderless and always-on-top, sized to the full physical
/// screen (logical pixels, which already account for DPI scaling). Because it
/// is topmost (HWND_TOPMOST) it is drawn above the always-on-top taskbar, so
/// the taskbar is obscured.
///
/// Unlike `setFullScreen(true)`, the window stays in the normal windowing
/// system: alt-tab, DWM composition, and the screenshot capture flow all keep
/// working (the capture flow hides the window before grabbing the screen, so
/// the desktop — not this window — is captured).
Future<void> coverTaskbar() async {
  final display = await screenRetriever.getPrimaryDisplay();
  // Full monitor rect in logical pixels (includes the taskbar area).
  final full = display.size;
  // Apply bounds first, then mark topmost. SetBounds uses HWND_TOP, which
  // does not clear the topmost style, but setting topmost last is safest.
  await windowManager.setBounds(Rect.fromLTWH(0, 0, full.width, full.height));
  await windowManager.setAlwaysOnTop(true);
}

/// Return the window to a normal windowed layout that always fits fully on
/// screen.
///
/// The desired [size] is clamped to the monitor's visible work area (the
/// region excluding the taskbar) so the window — including its top control
/// buttons (fullscreen / minimize / close) — is never pushed off the screen
/// edges on smaller displays. The window is horizontally centered and anchored
/// to the bottom of the work area, and stays topmost (always-on-top) so it
/// always sits above other windows.
Future<void> restoreWindowed({Size size = kDefaultWindowedSize}) async {
  final display = await screenRetriever.getPrimaryDisplay();
  // Work area = monitor minus the taskbar, in logical pixels (DPI already
  // accounted for). Fall back to the full size if the platform omits it.
  final Size work = display.visibleSize ?? display.size;
  final Offset workOrigin = display.visiblePosition ?? Offset.zero;

  // Leave a small margin so the frameless window never sits flush against the
  // screen edges, and never exceeds the usable area.
  const double margin = 32.0;
  final double w =
      size.width < work.width - margin ? size.width : work.width - margin;
  final double h =
      size.height < work.height - margin ? size.height : work.height - margin;

  // Horizontally centered, anchored to the bottom of the work area.
  final double left = workOrigin.dx + (work.width - w) / 2;
  final double top = workOrigin.dy + (work.height - h);

  await windowManager.setAlwaysOnTop(true);
  await windowManager.setBounds(Rect.fromLTWH(left, top, w, h));
}
