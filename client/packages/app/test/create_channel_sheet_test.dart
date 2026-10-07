// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The create-channel sheet's primary button names what is missing rather
/// than sitting disabled with no explanation - the same "say why" treatment
/// `poll_composer_sheet_test.dart` already covers for its own sheet - and
/// refuses a name past the server's own 64-character ceiling before ever
/// sending it.
///
/// The Private toggle is absent rather than disabled for a caller without
/// MANAGE_ROLES, the same convention `channel_settings_screen_test.dart`
/// covers for its own MANAGE_ROLES-gated section.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/create_channel_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _openSheet(
  WidgetTester tester, {
  int permissions = 0,
  String? categoryId,
  String? categoryName,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meProvider.overrideWith(
          (ref) async => api.Me(
            id: 'user-1',
            username: 'user-1',
            displayName: 'User',
            createdAt: 0,
            permissions: permissions,
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCreateChannelSheet(
                context,
                initialKind: 'text',
                categoryId: categoryId,
                categoryName: categoryName,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _nameField() => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Channel name',
);

AppButton _primaryButton(WidgetTester tester) => tester.widget<AppButton>(
  find.byWidgetPredicate(
    (w) => w is AppButton && w.variant == AppButtonVariant.primary,
  ),
);

Finder _privateToggle() => find.byWidgetPredicate(
  (w) => w is AppToggle && w.semanticLabel == 'Make this channel private',
);

const _compactWidth = 500.0;
const _desktopWidth = 1100.0;
const _windowHeight = 900.0;

void main() {
  for (final width in [_compactWidth, _desktopWidth]) {
    testWidgets('renders without overflow at width $width', (tester) async {
      tester.view.physicalSize = Size(width, _windowHeight);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _openSheet(tester, categoryId: 'cat-1', categoryName: 'Lounge');

      expect(tester.takeException(), isNull);
      expect(find.text('Create a channel'), findsOneWidget);
    });
  }

  testWidgets('the title reads as a heading, not a bolded paragraph', (
    tester,
  ) async {
    await _openSheet(tester);

    final title = tester.widget<Text>(find.text('Create a channel'));
    expect(title.style?.fontSize, AppText.heading.fontSize);
  });

  testWidgets('the 64-char limit counts down before it is hit', (tester) async {
    await _openSheet(tester);

    expect(find.text('0/64'), findsOneWidget);

    await tester.enterText(_nameField(), 'announcements');
    await tester.pump();

    expect(find.text('13/64'), findsOneWidget);
  });

  testWidgets(
    'a name of astral characters counts characters, not utf-16 units',
    (tester) async {
      await _openSheet(tester);

      await tester.enterText(_nameField(), List.filled(40, '\u{1F600}').join());
      await tester.pump();

      expect(find.text('40/64'), findsOneWidget);
      expect(_primaryButton(tester).disabled, isFalse);
    },
  );

  testWidgets('the Text/Voice choice says what each kind means', (
    tester,
  ) async {
    await _openSheet(tester);

    expect(
      find.text(
        'People post messages, images and files to read at their own pace.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Voice'));
    await tester.pump();

    expect(
      find.text(
        'People join a live call to talk, share video and their screen.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('names the category the channel lands in when one is implied', (
    tester,
  ) async {
    await _openSheet(tester, categoryId: 'cat-1', categoryName: 'Voice chat');

    expect(find.text('Adding to Voice chat'), findsOneWidget);
  });

  testWidgets('says nothing about a category when none is implied', (
    tester,
  ) async {
    await _openSheet(tester);

    expect(find.textContaining('Adding to'), findsNothing);
  });

  testWidgets('names what is missing rather than sitting disabled mute', (
    tester,
  ) async {
    await _openSheet(tester);

    expect(_primaryButton(tester).label, 'Add a channel name');
    expect(_primaryButton(tester).disabled, isTrue);

    await tester.enterText(_nameField(), 'announcements');
    await tester.pump();

    expect(_primaryButton(tester).label, 'Create channel');
    expect(_primaryButton(tester).disabled, isFalse);

    await tester.enterText(_nameField(), 'a' * 65);
    await tester.pump();

    expect(_primaryButton(tester).label, 'Name is too long');
    expect(_primaryButton(tester).disabled, isTrue);
  });

  testWidgets('the Private toggle is absent without MANAGE_ROLES', (
    tester,
  ) async {
    await _openSheet(tester, permissions: 0);

    expect(_privateToggle(), findsNothing);
  });

  testWidgets(
    'the Private toggle appears, defaults off, and can be switched on for a '
    'MANAGE_ROLES holder',
    (tester) async {
      await _openSheet(tester, permissions: Perm.manageRoles);

      expect(_privateToggle(), findsOneWidget);
      expect(tester.widget<AppToggle>(_privateToggle()).value, isFalse);

      await tester.tap(_privateToggle());
      await tester.pump();

      expect(tester.widget<AppToggle>(_privateToggle()).value, isTrue);
    },
  );

  testWidgets('Join muted is offered for a voice channel only, and defaults '
      'off', (tester) async {
    await _openSheet(tester);
    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle &&
          w.semanticLabel == 'Members join this channel muted',
    );
    expect(toggle, findsNothing);

    await tester.tap(find.text('Voice'));
    await tester.pump();

    expect(toggle, findsOneWidget);
    expect(tester.widget<AppToggle>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<AppToggle>(toggle).value, isTrue);
  });
}
