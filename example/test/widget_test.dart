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

      // Should contain text related to the app
      expect(find.text('libcimbar Example'), findsWidgets);
    });
  });
}
