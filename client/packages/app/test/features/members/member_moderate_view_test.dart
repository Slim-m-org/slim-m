// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Moderate sub-view in isolation: the roles checklist (with `@everyone`
/// shown but locked), the rights-gated sections, and the foot button.
///
/// `member_profile_test.dart` covers the row that opens this and the push/
/// back/Esc mechanics; this file is the content once it is open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_moderate_view.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _everyone = api.Role(
  id: 'role-everyone',
  name: 'everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);
const _grantable = api.Role(
  id: 'role-tester',
  name: 'tester',
  permissions: Perm.sendMessages,
  isEveryone: false,
  createdAt: 0,
);
const _ungrantable = api.Role(
  id: 'role-admin',
  name: 'admin-only',
  permissions: Perm.administrator,
  isEveryone: false,
  createdAt: 0,
);
const _botManaged = api.Role(
  id: 'role-bot',
  name: 'Echo Bot',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
  managedBotId: 'user-echo-bot',
);

const _profile = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
  roleIds: ['role-tester'],
);

Widget _harness({required Widget child, int permissions = Perm.sendMessages}) =>
    ProviderScope(
      overrides: [
        myPermissionsProvider.overrideWithValue(permissions),
        membersProvider.overrideWith((ref) async => [_profile]),
        rolesProvider.overrideWith(
          (ref) async => [_everyone, _grantable, _ungrantable, _botManaged],
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

MemberModerateView _view(
  BuildContext host, {
  bool canManageRoles = true,
  bool outranked = false,
  bool canOfferTimeoutChips = false,
  bool canRename = false,
  bool canIssueReset = false,
  bool canRemove = false,
  bool canEject = false,
  VoidCallback? onBack,
  VoidCallback? onRemove,
  VoidCallback? onEject,
  void Function(Duration)? onTimeOut,
}) => MemberModerateView(
  profile: _profile,
  host: host,
  canManageRoles: canManageRoles,
  outranked: outranked,
  canOfferTimeoutChips: canOfferTimeoutChips,
  canRename: canRename,
  canIssueReset: canIssueReset,
  canRemove: canRemove,
  canEject: canEject,
  onBack: onBack ?? () {},
  onTimeOut: onTimeOut ?? (_) {},
  onRemove: onRemove ?? () {},
  onEject: onEject ?? () {},
  onDone: () {},
);

void main() {
  testWidgets('everyone shows checked and locked, never toggleable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(child: Builder(builder: (context) => _view(context))),
    );
    await tester.pump();

    final everyoneRow = find.ancestor(
      of: find.text('everyone'),
      matching: find.byType(AppListRow),
    );
    expect(everyoneRow, findsOneWidget);
    expect(find.text('Always granted'), findsOneWidget);
    final toggle = tester.widget<AppToggle>(
      find.descendant(of: everyoneRow, matching: find.byType(AppToggle)),
    );
    expect(toggle.value, isTrue);
    expect(
      toggle.onChanged,
      isNull,
      reason: 'nothing here can ever change who holds @everyone',
    );
    expect(
      toggle.locked,
      isTrue,
      reason:
          'on and unchangeable reads as locked, not as an ordinary '
          'disabled switch',
    );
  });

  testWidgets('a role the caller cannot grant is shown, disabled, not hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        permissions: Perm.sendMessages,
        child: Builder(builder: (context) => _view(context)),
      ),
    );
    await tester.pump();

    expect(find.text('admin-only'), findsOneWidget);
    expect(find.text('Needs permissions you lack'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('admin-only'),
      matching: find.byType(AppListRow),
    );
    final toggle = tester.widget<AppToggle>(
      find.descendant(of: row, matching: find.byType(AppToggle)),
    );
    expect(toggle.onChanged, isNull);
    expect(
      toggle.locked,
      isFalse,
      reason: 'ungrantable is disabled, not the always-on locked style',
    );
  });

  testWidgets(
    'a bot-managed role carries the same Bot tag the roles screen uses',
    (tester) async {
      await tester.pumpWidget(
        _harness(child: Builder(builder: (context) => _view(context))),
      );
      await tester.pump();

      final row = find.ancestor(
        of: find.text('Echo Bot'),
        matching: find.byType(AppListRow),
      );
      expect(
        find.descendant(of: row, matching: find.text('BOT')),
        findsOneWidget,
        reason: 'AppBadge renders its label uppercased',
      );
    },
  );

  testWidgets(
    'a grantable role toggles by calling the shared assign/unassign routes',
    (tester) async {
      final calls = <String>[];
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(
            api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'self',
                accessToken: 'access',
                refreshToken: 'refresh',
                accessExpiresAt: 0,
              ),
            ),
          ),
          myPermissionsProvider.overrideWithValue(Perm.sendMessages),
          membersProvider.overrideWith((ref) async => [_profile]),
          rolesProvider.overrideWith((ref) async => [_everyone, _grantable]),
          mockApiOverride((request) async {
            calls.add('${request.method} ${request.url.path}');
            return http.Response('', 204);
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: Builder(builder: (context) => _view(context))),
          ),
        ),
      );
      await tester.pump();

      // maya already holds role-tester; this switches it off.
      final row = find.ancestor(
        of: find.text('tester'),
        matching: find.byType(AppListRow),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byType(AppToggle)),
      );
      await tester.pump();

      expect(
        calls,
        contains('DELETE /members/${_profile.id}/roles/role-tester'),
      );
    },
  );

  testWidgets('Remove is the outlined danger button at the foot, gated', (
    tester,
  ) async {
    var removed = false;
    await tester.pumpWidget(
      _harness(
        child: Builder(
          builder: (context) =>
              _view(context, canRemove: true, onRemove: () => removed = true),
        ),
      ),
    );
    await tester.pump();

    final button = tester.widget<AppButton>(
      find.widgetWithText(AppButton, 'Remove from Space...'),
    );
    expect(button.variant, AppButtonVariant.danger);

    await tester.tap(find.text('Remove from Space...'));
    expect(removed, isTrue);
  });

  testWidgets('Remove is absent without the right', (tester) async {
    await tester.pumpWidget(
      _harness(
        child: Builder(builder: (context) => _view(context, canRemove: false)),
      ),
    );
    await tester.pump();
    expect(find.text('Remove from Space...'), findsNothing);
  });

  testWidgets('the back chevron calls onBack', (tester) async {
    var back = false;
    await tester.pumpWidget(
      _harness(
        child: Builder(
          builder: (context) => _view(context, onBack: () => back = true),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Back'));
    expect(back, isTrue);
  });

  testWidgets('timeout chips and reset code each follow their own gate', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        child: Builder(
          builder: (context) =>
              _view(context, canOfferTimeoutChips: true, canIssueReset: true),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('TIME OUT'), findsOneWidget);
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('Password reset code...'), findsOneWidget);
  });

  testWidgets('an outranked member shows the reason in place of time out', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        child: Builder(builder: (context) => _view(context, outranked: true)),
      ),
    );
    await tester.pump();

    expect(
      find.text(
        'You cannot time out or remove maya: they hold permissions you do not.',
      ),
      findsOneWidget,
    );
    expect(find.text('TIME OUT'), findsNothing);
  });

  testWidgets('Rename is offered only where the gate allows it', (
    tester,
  ) async {
    for (final canRename in [true, false]) {
      await tester.pumpWidget(
        _harness(
          child: Builder(
            builder: (context) => _view(context, canRename: canRename),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Rename...'), canRename ? findsOneWidget : findsNothing);
    }
  });
}
