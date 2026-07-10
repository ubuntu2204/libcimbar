// Platform responsibilities:
//   Windows  → Encoder (screen capture + AVIF + cimbar encoding)
//   Android  → Decoder (camera + JNI decoding)
//   Web      → Decoder (camera + WASM decoding)

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'core/screenshot_capture.dart';
import 'encoder_page.dart';
import 'decoder_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Windows only: initialize window_manager for screenshot hide/show
  if (!kIsWeb && Platform.isWindows) {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1100, 750),
      center: true,
      title: 'libcimbar',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
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
  int _currentIndex = 0;

  // Windows only: show Encode tab
  bool get _isWindows => !kIsWeb && Platform.isWindows;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[];
    final navItems = <BottomNavigationBarItem>[];

    if (_isWindows) {
      pages.add(const EncoderPage());
      navItems.add(const BottomNavigationBarItem(
        icon: Icon(Icons.cast),
        label: 'Encode',
      ));
    }

    pages.add(const DecoderPage());
    navItems.add(const BottomNavigationBarItem(
      icon: Icon(Icons.qr_code_scanner),
      label: 'Decode',
    ));

    final index = _currentIndex.clamp(0, pages.length - 1);

    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: navItems.length > 1
          ? BottomNavigationBar(
              currentIndex: index,
              onTap: (i) => setState(() => _currentIndex = i),
              items: navItems,
            )
          : null,
    );
  }
}
