// Basic smoke test for CO2 Monitor.
import 'package:flutter_test/flutter_test.dart';

import 'package:capnography_co2/main.dart';

void main() {
  testWidgets('App boots to home', (WidgetTester tester) async {
    await tester.pumpWidget(const CapnographyApp());
    await tester.pump();
    expect(find.text('CO₂ MONITOR'), findsWidgets);
  });
}
