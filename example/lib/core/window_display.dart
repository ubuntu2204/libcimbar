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

/// Return the window to a normal windowed layout: horizontally centered and
/// vertically centered but nudged up a little.
///
/// The desired [size] is clamped so the window keeps a margin on every side —
/// this keeps the top control buttons (fullscreen / minimize / close) on-screen
/// even on small displays. It is made topmost *after* positioning (same order
/// as [coverTaskbar]) so Windows always draws it above the taskbar instead of
/// hiding it behind the taskbar.
Future<void> restoreWindowed({Size size = kDefaultWindowedSize}) async {
  final display = await screenRetriever.getPrimaryDisplay();
  // Full monitor size in logical pixels (DPI already accounted for).
  final Size screen = display.size;

  // Keep a margin on every side so the window never touches the screen edges
  // and the top control buttons stay on-screen even on small displays.
  const double topMargin = 40.0;
  const double bottomMargin = 40.0;
  const double sideMargin = 24.0;
  // How far above the exact vertical center to sit ("稍微上点").
  const double upwardNudge = 48.0;
  final double maxW = screen.width - sideMargin * 2;
  final double maxH = screen.height - topMargin - bottomMargin;
  final double w = size.width < maxW ? size.width : maxW;
  final double h = size.height < maxH ? size.height : maxH;

  // Horizontally centered; vertically centered then nudged up, clamped so the
  // top control buttons never leave the screen.
  final double left = (screen.width - w) / 2;
  double top = (screen.height - h) / 2 - upwardNudge;
  if (top < topMargin) top = topMargin;

  // Apply bounds first, then mark topmost LAST so Windows draws the window
  // above the taskbar (same ordering as coverTaskbar).
  await windowManager.setBounds(Rect.fromLTWH(left, top, w, h));
  await windowManager.setAlwaysOnTop(true);
}
