// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two member card layouts: someone else's (Message and Add note up top,
/// "In #channel" removal when opened from a channel you manage) and your own
/// (activity, then Set status, Copy username, Profile settings), at popover
/// and phone width, in both themes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/presence_activity.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/providers/user_notes.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';

import 'support/call_header_fixture.dart' show FakePresence;
import 'ui_snapshot_support.dart';

const _channelId = 'channel-voice';

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'Maya Chen',
  createdAt: 1788000000000,
  roles: ['member'],
  roleIds: ['role-member'],
  about: 'Plays too much synth. Ask me about modular.',
);

const _me = api.Me(
  id: 'user-maya',
  username: 'maya',
  displayName: 'Maya Chen',
  createdAt: 1788000000000,
  permissions: 0,
);

const _spotify = api.PresenceActivity(
  kind: api.ActivityKind.listening,
  title: 'Venom',
  subtitle: r'$uicideboy$, Shakewell',
  source: 'Spotify',
);

data.Channel get _channel => const data.Channel(
  id: _channelId,
  name: 'voice',
  kind: 'voice',
  createdAt: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  isPersonalSpace: false,
  joinMuted: false,
  position: 0,
  slowModeSeconds: 0,
);

Widget _harness(
  Widget Function(BuildContext) body, {
  bool self = false,
  String? note,
  api.PresenceActivity? activity,
  int channelPermissions = 0,
  Brightness brightness = Brightness.light,
  double width = 320,
  bool sheet = false,
}) {
  final tokens = brightness == Brightness.dark
      ? AppTokens.dark
      : AppTokens.light;
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      presenceControllerProvider.overrideWith(
        (ref) => FakePresence(ref, {
          _other.id: self ? api.PresenceState.online : api.PresenceState.away,
        }),
      ),
      myPermissionsProvider.overrideWithValue(0),
      membersProvider.overrideWith((ref) async => [_other]),
      rolesProvider.overrideWith((ref) async => const <api.Role>[]),
      userNoteProvider.overrideWith(
        (ref, id) async => api.UserNote(body: note, updatedAt: null),
      ),
      channelByIdProvider.overrideWith((ref, id) => Stream.value(_channel)),
      channelPermissionsProvider.overrideWith(
        (ref, id) async => channelPermissions,
      ),
      if (self) meProvider.overrideWith((ref) async => _me),
      if (activity != null)
        presenceActivityProvider.overrideWith(
          (ref) => PresenceActivityController()..apply(_other.id, activity),
        ),
    ],
    child: MaterialApp(
      theme: buildTheme(brightness, tokens),
      home: Scaffold(
        backgroundColor: sheet ? tokens.surfaceRaised : tokens.surfaceBase,
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.all(sheet ? 0 : 10),
              child: SizedBox(
                width: sheet ? width : width - 20,
                child: RepaintBoundary(
                  key: snapshotBoundary,
                  child: ColoredBox(
                    color: sheet ? tokens.surfaceRaised : tokens.surfaceBase,
                    child: Builder(builder: body),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _card({String? channelId, bool compact = false}) => MemberProfileBody(
  profile: _other,
  compact: compact,
  channelId: channelId,
  onDone: () {},
);

Future<void> _pump(WidgetTester tester, Widget harness, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(harness);
  await tester.pump();
  await tester.pump();
}

Future<void> _snap(WidgetTester tester, String name) async {
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  group('another member', () {
    testWidgets('Message and Add note lead, moderation rows follow', (
      tester,
    ) async {
      await _pump(tester, _harness((_) => _card()));

      expect(find.text('@maya'), findsOneWidget);
      expect(find.text('Away'), findsOneWidget);
      expect(find.text('MEMBER'), findsOneWidget);
      expect(find.textContaining('Joined'), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);
      expect(find.text('Add note'), findsOneWidget);
      expect(find.text('Report user'), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
      expect(find.text('Set status'), findsNothing);
      expect(find.textContaining('last seen'), findsNothing);
      expect(find.text('Add a private note'), findsNothing);
    });

    testWidgets('Add note reveals the private note field and focuses it', (
      tester,
    ) async {
      await _pump(tester, _harness((_) => _card()));

      await tester.tap(find.text('Add note'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Add a private note'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('an existing note is shown without the Add note button', (
      tester,
    ) async {
      await _pump(tester, _harness((_) => _card(), note: 'met at the meetup'));

      expect(find.text('Add note'), findsNothing);
      expect(find.text('met at the meetup'), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);
    });

    testWidgets('opened from a channel, the In #channel section appears', (
      tester,
    ) async {
      await _pump(
        tester,
        _harness(
          (_) => _card(channelId: _channelId),
          channelPermissions: Perm.manageRoles,
        ),
      );

      expect(find.text('IN #VOICE'), findsOneWidget);
      expect(find.text('Notify me off hours'), findsOneWidget);
      expect(find.text('Remove from #voice'), findsOneWidget);
    });

    testWidgets('without a channel context there is no channel section', (
      tester,
    ) async {
      await _pump(tester, _harness((_) => _card()));

      expect(find.textContaining('IN #'), findsNothing);
      expect(find.text('Notify me off hours'), findsOneWidget);
      expect(find.textContaining('Remove from #'), findsNothing);
    });

    testWidgets('a channel without manage rights has no channel section', (
      tester,
    ) async {
      await _pump(tester, _harness((_) => _card(channelId: _channelId)));

      expect(find.textContaining('IN #'), findsNothing);
      expect(find.text('Notify me off hours'), findsOneWidget);
      expect(find.textContaining('Remove from #'), findsNothing);
    });

    testWidgets('the activity sits in its own box with no invented progress', (
      tester,
    ) async {
      await _pump(tester, _harness((_) => _card(), activity: _spotify));

      expect(find.text('LISTENING ON SPOTIFY'), findsOneWidget);
      expect(find.text('Venom'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  group('your own card', () {
    testWidgets('is the preview plus Set status, Copy username, settings', (
      tester,
    ) async {
      await _pump(tester, _harness((_) => _card(), self: true));

      expect(find.text('YOU'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Set status'), findsOneWidget);
      expect(find.text('Copy username'), findsOneWidget);
      expect(find.text('Profile settings'), findsOneWidget);
      for (final other in ['Message', 'Add note', 'Report user', 'Block']) {
        expect(find.text(other), findsNothing, reason: other);
      }
    });

    testWidgets('Copy username puts @username on the clipboard and says so', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(tester, _harness((_) => _card(), self: true));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MemberProfileBody)),
      );

      await tester.tap(find.text('Copy username'));
      await tester.pump();
      await tester.pump();

      expect(copied, '@maya');
      expect(
        container.read(toastsProvider).map((t) => t.message),
        contains('Username copied.'),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Set status opens the status editor', (tester) async {
      await _pump(tester, _harness((_) => _card(), self: true));

      await tester.tap(find.text('Set status'));
      await tester.pumpAndSettle();

      expect(find.text('Set a status'), findsOneWidget);
    });

    testWidgets('shows the activity box', (tester) async {
      await _pump(
        tester,
        _harness((_) => _card(), self: true, activity: _spotify),
      );

      expect(find.text('LISTENING ON SPOTIFY'), findsOneWidget);
    });
  });

  group('snapshots', () {
    for (final brightness in Brightness.values) {
      final theme = brightness.name;
      for (final self in [false, true]) {
        final who = self ? 'self' : 'other';
        testWidgets('$who popover $theme', (tester) async {
          await _pump(
            tester,
            _harness(
              (_) => _card(channelId: _channelId),
              self: self,
              activity: self ? _spotify : null,
              channelPermissions: Perm.manageRoles,
              brightness: brightness,
              width: 320,
            ),
          );
          await _snap(tester, 'member-card-$who-popover-$theme');
        });

        testWidgets('$who phone $theme', (tester) async {
          await _pump(
            tester,
            _harness(
              (_) => _card(channelId: _channelId, compact: true),
              self: self,
              activity: self ? _spotify : null,
              channelPermissions: Perm.manageRoles,
              brightness: brightness,
              width: 390,
              sheet: true,
            ),
            size: const Size(390, 900),
          );
          await _snap(tester, 'member-card-$who-phone-$theme');
        });
      }
    }
  });
}
