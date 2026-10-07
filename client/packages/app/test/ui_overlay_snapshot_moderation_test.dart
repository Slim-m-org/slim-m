// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member profile popover's own permission-combination matrix: which
/// sections are present, absent, or (once) present-and-then-failing,
/// depending on the caller's bits, the target's own state, and whether the
/// two share a live call.
///
/// `MemberProfileBody` is pumped directly rather than through
/// `showMemberProfile`, the same choice `member_profile_test.dart` and
/// `member_profile_eject_test.dart` already make: the section-composition
/// rule under test lives in the body, and the popover chrome around it is
/// already proven by the `member-profile-popover` entry in
/// `ui_overlay_snapshot_test.dart`'s own `_overlays` map.
///
/// See screen-inventory-moderation.md's "Member popover permission-
/// combination matrix" for what each state below is named after. One
/// viewport (desktop); the compact presentation carries the same rows per
/// `member_profile_test.dart`'s own already-passing coverage.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart' show FakeSession, tokens;

const _viewport = Size(1400, 880);
const _channelId = 'channel-shared';

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'Maya',
  createdAt: 0,
);

final _timedOut = api.UserProfile(
  id: _other.id,
  username: _other.username,
  displayName: _other.displayName,
  createdAt: 0,
  timedOutUntil: DateTime.now()
      .add(const Duration(hours: 1))
      .millisecondsSinceEpoch,
);

/// A fixed block set with no real fetch, the shape `member_profile_block_
/// test.dart` already uses.
class _FixedBlocks extends BlocksController {
  _FixedBlocks(super.ref, BlocksState fixed) {
    state = fixed;
  }

  @override
  Future<void> refresh() async {}
}

Widget _body(api.UserProfile profile) =>
    MemberProfileBody(profile: profile, compact: false, onDone: () {});

Widget _harness(
  Widget child, {
  int permissions = 0,
  List<api.UserProfile> members = const [],
  api.Me? selfProfile,
  Set<String> blocked = const {},
}) => ProviderScope(
  overrides: [
    myPermissionsProvider.overrideWithValue(permissions),
    membersProvider.overrideWith((ref) async => members),
    if (selfProfile != null)
      meProvider.overrideWith((ref) async => selfProfile),
    blocksProvider.overrideWith(
      (ref) => _FixedBlocks(ref, BlocksState(ids: blocked, settled: true)),
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 320,
          child: RepaintBoundary(key: snapshotBoundary, child: child),
        ),
      ),
    ),
  ),
);

Future<void> _pump(WidgetTester tester, Widget harness) async {
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(harness);
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

/// Unmounts the tree and disposes the container inside the test body.
// The pending-timer check runs before tearDowns, so a disposal left to one sees the sync retry timer.
Future<void> _unmountAndDispose(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

/// Leaves the call, then [_unmountAndDispose].
Future<void> _endCall(
  WidgetTester tester,
  ({ProviderContainer container}) wired,
) async {
  await wired.container.read(voiceControllerProvider.notifier).leave();
  await _unmountAndDispose(tester, wired.container);
}

/// Joins a real, live-participant call for real (a mocked token round trip
/// plus a driven [FakeSession]), the shared shape `member_profile_eject_
/// test.dart` uses for both the call section and the Eject row: both need
/// `inCallTogether` to actually be true, which no permission override alone
/// can fake.
///
/// The extra trailing pump is a mid-flight capture `expectSettled` found
/// directly: `_other`'s avatar has no cached bytes, so `UserAvatar` asks
/// `avatarBytesProvider`, whose fetch answers 204 under this test's own
/// catch-all `MockClient` - `FetchedBytes` reads that as "found, zero
/// bytes" rather than "no avatar", and `AppAvatar`'s `Image.errorBuilder`
/// only reports the resulting decode failure a frame or two later. One
/// pump captured the avatar mid-decode with no initials text yet; the
/// second is what lets the fallback "MA" land before `_finish` reads the
/// tree. Reverting this pump does not change the written PNG at all -
/// `writeSnapshot`'s own real-shadow repaint gives the same pending decode
/// enough turns to resolve before the pixels are rasterised, which is
/// exactly why this needed the widget-tree gate rather than a screenshot
/// diff: the bug was real and invisible to every prior look at the image.
Future<({ProviderContainer container})> _pumpInCall(
  WidgetTester tester, {
  required int permissions,
}) async {
  final session = FakeSession();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      myPermissionsProvider.overrideWithValue(permissions),
      membersProvider.overrideWith((ref) async => [_other]),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/voice/token')) {
              return http.Response(
                jsonEncode({
                  'url': 'wss://sfu.example.com',
                  'room': _channelId,
                  'token': 'jwt',
                  'expires_at': 0,
                  'can_publish': true,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
    ],
  );
  addTearDown(container.dispose);

  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: RepaintBoundary(
                  key: snapshotBoundary,
                  child: _body(_other),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await container.read(voiceControllerProvider.notifier).join(_channelId);
  session.emitState(VoiceSessionState.connected);
  session.emitParticipants([
    VoiceParticipant(
      identity: _other.id,
      name: _other.displayName,
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
    ),
  ]);
  await tester.pump();
  await tester.pump();
  return (container: container);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('own row: only Profile settings, no moderation, no report', (
    tester,
  ) async {
    await _pump(
      tester,
      _harness(
        _body(_other),
        selfProfile: api.Me(
          id: _other.id,
          username: _other.username,
          displayName: _other.displayName,
          createdAt: 0,
          permissions: -1,
        ),
      ),
    );
    await _finish(tester, 'member-popover-self-desktop');
  });

  testWidgets('a plain member: social verbs and Block, nothing else', (
    tester,
  ) async {
    await _pump(tester, _harness(_body(_other)));
    await _finish(tester, 'member-popover-plain-desktop');
  });

  testWidgets('blockable: default Block, danger-toned', (tester) async {
    await _pump(tester, _harness(_body(_other)));
    await _finish(tester, 'member-popover-blockable-desktop');
  });

  testWidgets('already blocked: Unblock replaces Block', (tester) async {
    await _pump(tester, _harness(_body(_other), blocked: {_other.id}));
    await _finish(tester, 'member-popover-blocked-desktop');
  });

  testWidgets('timed out, viewer can lift it', (tester) async {
    await _pump(
      tester,
      _harness(_body(_timedOut), permissions: Perm.kickMembers),
    );
    await _finish(tester, 'member-popover-timeout-badge-liftable-desktop');
  });

  testWidgets('timed out, viewer cannot lift it', (tester) async {
    await _pump(tester, _harness(_body(_timedOut)));
    await _finish(tester, 'member-popover-timeout-badge-readonly-desktop');
  });

  testWidgets('not timed out, viewer can time them out: the duration chips', (
    tester,
  ) async {
    await _pump(tester, _harness(_body(_other), permissions: Perm.kickMembers));
    await _finish(tester, 'member-popover-timeout-chips-desktop');
  });

  testWidgets('MANAGE_ROLES: the Roles... row appears', (tester) async {
    await _pump(tester, _harness(_body(_other), permissions: Perm.manageRoles));
    await _finish(tester, 'member-popover-roles-desktop');
  });

  testWidgets(
    'call section only, no Eject: inCallTogether without KICK_MEMBERS',
    (tester) async {
      final wired = await _pumpInCall(tester, permissions: 0);
      await _finish(tester, 'member-popover-call-audio-only-desktop');
      await _endCall(tester, wired);
    },
  );

  testWidgets('Eject appears once both KICK_MEMBERS and a shared call are '
      'true', (tester) async {
    final wired = await _pumpInCall(tester, permissions: Perm.kickMembers);
    await _finish(tester, 'member-popover-eject-desktop');
    await _endCall(tester, wired);
  });

  testWidgets('a timeout attempt that the row offered and the server '
      'refuses: the containment gap - the client never preflights that its '
      "own permissions actually contain the target's", (tester) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
        myPermissionsProvider.overrideWithValue(Perm.kickMembers),
        membersProvider.overrideWith((ref) async => [_other]),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('/timeout')) {
                return http.Response('{"error":"forbidden"}', 403);
              }
              return http.Response('{}', 200);
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: RepaintBoundary(
                  key: snapshotBoundary,
                  child: _body(_other),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // The row renders exactly as it would for a target the caller can moderate.
    await tester.tap(find.text('Moderate...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5m'));
    await tester.pumpAndSettle();

    // A plain 403 gives the same "not allowed" sentence any denied caller sees; there is no distinct wording for a containment gap.
    expect(find.textContaining('not allowed to do that'), findsOneWidget);
    await _finish(tester, 'member-popover-admin-containment-gap-desktop');
    await _unmountAndDispose(tester, container);
  });
}
