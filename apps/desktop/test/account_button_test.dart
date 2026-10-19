import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/account_button.dart';

void main() {
  testWidgets(
    'saved accounts can be selected, signed out individually, and added',
    (tester) async {
      final selections = <String>[];
      final signOuts = <String>[];
      var additions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountButton(
              connected: true,
              busy: false,
              account: 'alex',
              displayName: 'Alex',
              email: 'alex@example.test',
              photoUrl: '',
              accounts: const [
                {
                  'id': 'alex',
                  'displayName': 'Alex',
                  'email': 'alex@example.test',
                  'photoUrl': '',
                  'current': true,
                },
                {
                  'id': 'sam',
                  'displayName': 'Sam',
                  'email': 'sam@example.test',
                  'photoUrl': '',
                  'current': false,
                },
              ],
              onSignIn: () => fail('Already signed in'),
              onAddAccount: () => additions++,
              onSwitchAccount: selections.add,
              onSignOutAccount: signOuts.add,
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.byTooltip('Google account: alex@example.test'));
        await tester.pumpAndSettle();
      }

      await open();
      await tester.tap(find.text('sam@example.test'));
      await tester.pumpAndSettle();
      expect(selections, ['sam']);
      await open();
      await tester.tap(find.byTooltip('Sign out of sam@example.test'));
      await tester.pumpAndSettle();
      expect(signOuts, ['sam']);
      expect(selections, ['sam']);
      await open();
      await tester.tap(find.text('Add another account'));
      await tester.pumpAndSettle();
      expect(additions, 1);
    },
  );
  testWidgets('signed out account control opens sign-in and obeys busy state', (
    tester,
  ) async {
    var invitations = 0;
    Future<void> show({bool busy = false}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountButton(
            connected: false,
            busy: busy,
            displayName: '',
            email: '',
            photoUrl: '',
            onAddAccount: () {},
            onSwitchAccount: (_) {},
            onSignIn: () => invitations++,
            onSignOutAccount: (_) => fail('Not signed in'),
          ),
        ),
      ),
    );
    await show();
    await tester.tap(find.byTooltip('Sign in with Google'));
    expect(invitations, 1);
    await show(busy: true);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
  });

  testWidgets(
    'Google avatar failure falls back to initial and account menu signs out',
    (tester) async {
      var signOuts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountButton(
              connected: true,
              busy: false,
              displayName: 'Alex Example',
              email: 'alex@example.test',
              photoUrl: 'https://example.test/avatar.png',
              onAddAccount: () {},
              onSwitchAccount: (_) {},
              onSignIn: () => fail('Already signed in'),
              onSignOutAccount: (_) => signOuts++,
            ),
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as NetworkImage).url,
        'https://example.test/avatar.png',
      );
      // Flutter's test HTTP client rejects the image; a failed photo must leave
      // the account button usable rather than surfacing an image exception.
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Google account: alex@example.test'));
      await tester.pumpAndSettle();
      expect(find.text('Alex Example'), findsOneWidget);
      expect(find.text('alex@example.test'), findsOneWidget);
      expect(find.text('Add another account'), findsOneWidget);
      await tester.tap(find.byTooltip('Sign out of alex@example.test'));
      await tester.pumpAndSettle();
      expect(signOuts, 1);
    },
  );

  testWidgets(
    'identity changes replace photo and sign-out removes account menu',
    (tester) async {
      Future<void> show(bool connected, String email, String photo) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: AccountButton(
                  connected: connected,
                  busy: false,
                  displayName: '',
                  email: email,
                  photoUrl: photo,
                  onAddAccount: () {},
                  onSwitchAccount: (_) {},
                  onSignIn: () {},
                  onSignOutAccount: (_) {},
                ),
              ),
            ),
          );
      await show(true, 'first@example.test', 'file:///private/avatar.png');
      expect(find.byType(Image), findsNothing);
      expect(find.text('F'), findsOneWidget);
      await show(true, 'second@example.test', '');
      expect(
        find.byTooltip('Google account: second@example.test'),
        findsOneWidget,
      );
      expect(find.text('S'), findsOneWidget);
      await show(false, '', '');
      expect(find.text('Sign out'), findsNothing);
      expect(find.byTooltip('Sign in with Google'), findsOneWidget);
    },
  );
}
