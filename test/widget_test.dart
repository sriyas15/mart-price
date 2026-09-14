// This is a basic Flutter widget test.
//
// The default test has been updated to match the MartCompareApp widget.

import 'package:flutter_test/flutter_test.dart';
import 'package:mart_price/main.dart';

void main() {
  testWidgets('App renders MartCompare title', (WidgetTester tester) async {
    await tester.pumpWidget(const MartCompareApp());
    expect(find.text('MartCompare'), findsOneWidget);
  });
}
