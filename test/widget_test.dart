import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mower_phone_app/main.dart';

void main() {
  testWidgets('shows the disconnected mower controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MowerApp());

    expect(find.text('Mower Phone'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Zero mower'), findsOneWidget);
    expect(find.text('Status: Disconnected'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });
}
