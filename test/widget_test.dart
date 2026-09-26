import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onfeed/main.dart';

void main() {
  testWidgets('app opens on the discover screen', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ReelishApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Discover'), findsOneWidget);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
  });
}
