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

/// Return the window to a normal, bottom-anchored windowed layout that stays
/// on top of (above) the taskbar.
///
/// The desired [size] is clamped so the window never exceeds the monitor and
/// always leaves a top margin — this keeps the top control buttons (fullscreen
/// / minimize / close) on-screen even on small displays. The window is
/// horizontally centered and its bottom edge is flush with the screen bottom,
/// so it sits over the taskbar area. Because it is made topmost *after*
/// positioning (same order as [coverTaskbar]), Windows draws it above the
/// always-on-top taskbar instead of hiding it behind the taskbar.
Future<void> restoreWindowed({Size size = kDefaultWindowedSize}) async {
  final display = await screenRetriever.getPrimaryDisplay();
  // Full monitor size in logical pixels (DPI already accounted for).
  final Size screen = display.size;

  // Keep the top of the window (and its control buttons) on-screen, and leave
  // a small gap on the sides so it reads as a window rather than full screen.
  const double topMargin = 40.0;
  const double sideMargin = 24.0;
  final double maxW = screen.width - sideMargin * 2;
  final double maxH = screen.height - topMargin;
  final double w = size.width < maxW ? size.width : maxW;
  final double h = size.height < maxH ? size.height : maxH;

  // Horizontally centered, bottom edge flush with the screen bottom so the
  // window covers the taskbar area rather than stopping above it.
  final double left = (screen.width - w) / 2;
  final double top = screen.height - h;

  // Apply bounds first, then mark topmost LAST so Windows draws the window
  // above the taskbar (this ordering is what makes it cover the taskbar).
  await windowManager.setBounds(Rect.fromLTWH(left, top, w, h));
  await windowManager.setAlwaysOnTop(true);
}
