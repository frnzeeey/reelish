import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onfeed/main.dart';

void main() {
  testWidgets('app opens on the home screen', (tester) async {
    // The consent screen is covered separately; this test starts after it.
    SharedPreferences.setMockInitialValues({
      'reelish.legal.documentsAccepted.v1': true,
    });

    await tester.pumpWidget(const ReelishApp());
    // Let fail-closed startup network lookups reach their DNS timeout so the
    // widget test does not finish with a pending timer.
    await tester.pump(const Duration(seconds: 6));

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}
