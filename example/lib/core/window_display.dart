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

/// Return the window to a normal, centered windowed size.
///
/// The window stays topmost (always-on-top) so it remains above the Windows
/// taskbar in windowed mode too — only its size changes from the full-screen
/// [coverTaskbar] layout back to [kDefaultWindowedSize].
Future<void> restoreWindowed({Size size = kDefaultWindowedSize}) async {
  await windowManager.setAlwaysOnTop(true);
  await windowManager.setSize(size);
  await windowManager.center();
}
