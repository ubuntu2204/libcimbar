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

  // Initialize window_manager (required for hide/show during screenshot)
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
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

  // Set navigator key for screenshot overlay (needs context without BuildContext)
  ScreenshotCapture.navigatorKey = navigatorKey;

  // Initialize hotkey manager
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
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

  bool get _isEncoderPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[];
    final navItems = <BottomNavigationBarItem>[];

    if (_isEncoderPlatform) {
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
