import 'package:flutter/material.dart';
import 'decoder_page.dart';

void main() {
  runApp(const DecoderApp());
}

class DecoderApp extends StatelessWidget {
  const DecoderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'libcimbar 解码器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const Scaffold(body: DecoderPage()),
    );
  }
}
