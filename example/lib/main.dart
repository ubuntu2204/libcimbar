// Platform responsibilities:
//   Windows  → Encoder (screen capture + AVIF + cimbar encoding)
//   Android / Web → see decode_example project

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'core/screenshot_capture.dart';
import 'encoder_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Windows only: initialize window_manager for screenshot hide/show
  if (!kIsWeb && Platform.isWindows) {
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
      // Enter fullscreen so the encoder fills the whole monitor and covers
      // the Windows taskbar while displaying cimbar frames for capture.
      await windowManager.setFullScreen(true);
    });
  }

  // Windows only: set navigator key for screenshot overlay
  if (!kIsWeb && Platform.isWindows) {
    ScreenshotCapture.navigatorKey = navigatorKey;
  }

  // Windows only: initialize hotkey manager
  if (!kIsWeb && Platform.isWindows) {
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
  bool get _isWindows => !kIsWeb && Platform.isWindows;

  @override
  Widget build(BuildContext context) {
    if (_isWindows) {
      return const Scaffold(body: EncoderPage());
    }
    return const Scaffold(
      body: Center(child: Text('Encoder is only available on Windows.')),
    );
  }
}
