import 'package:flutter_test/flutter_test.dart';
import 'package:decode_example/main.dart';

void main() {
  testWidgets('DecoderApp builds', (WidgetTester tester) async {
    await tester.pumpWidget(const DecoderApp());
    expect(find.text('libcimbar Decoder'), findsOneWidget);
  });
}
