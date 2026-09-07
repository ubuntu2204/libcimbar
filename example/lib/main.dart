// Platform responsibilities:
//   Windows / Linux → Encoder (pick file → encode → display)
//   Android / Web   → see decode_example project

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'core/window_display.dart';
import 'encoder_page.dart';

/// Desktop platforms that can run the encoder (Windows + Linux).
bool get isEncoderDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop only: initialize window_manager.
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
        // it stays above the taskbar.
        await restoreWindowed();
      }
    });
  }

  runApp(const LibcimbarExampleApp());
}

class LibcimbarExampleApp extends StatelessWidget {
  const LibcimbarExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      body: Center(child: Text('编码器仅支持 Windows/Linux 桌面端。')),
    );
  }
}
