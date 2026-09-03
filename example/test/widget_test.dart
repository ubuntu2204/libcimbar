import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:libcimbar_example/main.dart';

void main() {
  group('LibcimbarExampleApp', () {
    testWidgets('app builds without error', (WidgetTester tester) async {
      await tester.pumpWidget(const LibcimbarExampleApp());
      await tester.pump();

      // The app should render something
      expect(find.byType(LibcimbarExampleApp), findsOneWidget);
    });

    testWidgets('home page renders', (WidgetTester tester) async {
      await tester.pumpWidget(const LibcimbarExampleApp());
      await tester.pumpAndSettle();

      // Should find the HomePage
      expect(find.byType(HomePage), findsOneWidget);
    });

    testWidgets('app title is set', (WidgetTester tester) async {
      await tester.pumpWidget(const LibcimbarExampleApp());
      await tester.pumpAndSettle();

      // MaterialApp.title names the app to the OS (task switcher / window
      // title). It is NOT rendered as a Text widget, so find.text() can never
      // match it — assert the property itself instead.
      //
      // (Note this is deliberately different from the desktop window title,
      // which main.dart sets to 'libcimbar' via WindowOptions.)
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.title, 'libcimbar Example');
    });
  });
}
