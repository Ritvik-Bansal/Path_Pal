import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathpal/widgets/map_widget.dart';

void main() {
  testWidgets('shows a fallback when no airport data is available',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MapWidget(contributorData: {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('No map data available'), findsOneWidget);
  });
}
