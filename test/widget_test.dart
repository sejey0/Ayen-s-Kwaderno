import 'package:flutter_test/flutter_test.dart';
import 'package:ayens_kwaderno/main.dart';

void main() {
  testWidgets('Ayens Kwaderno smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const AyensKwadernoApp());

    // Verify that the welcoming header renders
    expect(find.text("Ayen's Kwaderno"), findsOneWidget);
  });
}
