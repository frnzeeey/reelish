import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onfeed/main.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';

StoredSession _session() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return StoredSession(
    sessionId: 'session',
    accessToken: 'access',
    accessExpiresAt: now + 900,
    refreshToken: 'refresh',
    refreshExpiresAt: now + 86400,
    userId: 'user',
    username: 'viewer',
  );
}

void main() {
  late AccountController original;
  setUp(() {
    original = AccountController.instance;
    // The consent screen is covered separately; these tests start after it.
    SharedPreferences.setMockInitialValues({
      'reelish.legal.documentsAccepted.v1': true,
    });
  });
  tearDown(() => AccountController.instance = original);

  testWidgets('a signed-in app opens on the home screen', (tester) async {
    AccountController.instance = AccountController(
      store: MemorySessionStore(_session()),
    );
    await tester.pumpWidget(const ReelishApp());
    // Let fail-closed startup network lookups reach their DNS timeout so the
    // widget test does not finish with a pending timer.
    await tester.pump(const Duration(seconds: 6));

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('without a session the app asks to sign in with Trakt', (
    tester,
  ) async {
    AccountController.instance = AccountController(store: MemorySessionStore());
    await tester.pumpWidget(const ReelishApp());
    await tester.pump(const Duration(seconds: 6));

    expect(find.text('Sign in with Trakt'), findsWidgets);
    expect(find.text('Home'), findsNothing);
  });
}
