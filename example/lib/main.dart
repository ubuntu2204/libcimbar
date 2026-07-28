// Platform responsibilities:
//   Windows / Linux → Encoder (screen capture on Windows; test payload on both)
//   Android / Web → see decode_example project

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'core/screenshot_capture.dart';
import 'core/window_display.dart';
import 'encoder_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Desktop platforms that can run the encoder (Windows + Linux).
bool get isEncoderDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop only: initialize window_manager for screenshot hide/show
  if (isEncoderDesktop) {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1400, 1100),
      center: true,
      title: 'libcimbar',
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setAsFrameless();
      await windowManager.show();
      await windowManager.focus();
      if (Platform.isLinux) {
        // Linux (esp. Wayland/GNOME): the dock & top bar live above the
        // keep-above layer, so a windowed layout CANNOT stay in front of the
        // taskbar. Start directly in cover mode — the WM fullscreen layer is
        // the only layer guaranteed to draw over panels.
        await coverTaskbar();
      } else {
        // Windows: start in a normal centered windowed size, kept topmost so
        // it stays above the taskbar. This is NOT fullscreen mode, so the
        // screenshot capture flow keeps working (it hides the window before
        // grabbing).
        await restoreWindowed();
      }
    });
  }

  // Desktop only: set navigator key for screenshot overlay
  if (isEncoderDesktop) {
    ScreenshotCapture.navigatorKey = navigatorKey;
  }

  // Desktop only: initialize hotkey manager
  if (isEncoderDesktop) {
    await hotKeyManager.unregisterAll();
  }

  runApp(const LibcimbarExampleApp());
}

class LibcimbarExampleApp extends StatelessWidget {
  const LibcimbarExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'libcimbar Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    if (isEncoderDesktop) {
      return const Scaffold(body: EncoderPage());
    }
    return const Scaffold(
      body: Center(child: Text('Encoder is only available on Windows/Linux.')),
    );
  }
}
