// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// First-run setup over the channel shell, step by step and with a save that
/// the server refuses. Phone and desktop, dark and light: full screen under
/// 600 wide, a card over the dimmed shell from there.
///
/// Setup opens through the controller's own due check for a five-minute-old
/// account, so what is captured is the gate the app really mounts.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/first_run/providers/first_run_controller.dart';
import 'package:slimm_app/src/features/settings/providers/notification_preference_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_app/src/widgets/space_banner.dart';

import '../features/first_run/first_run_harness.dart' show FakePush, harnessNow;
import '../features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController;
import '../ui_snapshot_support.dart' show fixtureResponse;
import 'review_auth_support.dart';
import 'review_support.dart';

/// Everything the fixture answers, except saving a profile, which the server refuses.
final _profileSaveRefused = apiProvider.overrideWith(
  (ref) => api.SlimmApi(
    baseUrl: Uri.parse(authServer),
    session: ref.watch(sessionProvider),
    httpClient: MockClient(
      (request) async => request.method == 'PATCH' && request.url.path == '/me'
          ? jsonResponse({
              'error': 'you cannot change your profile right now',
            }, 403)
          : fixtureResponse(request),
    ),
  ),
);

final _newcomer = api.Me(
  id: 'user-nick',
  username: 'nick',
  displayName: 'Nick',
  createdAt: harnessNow
      .subtract(const Duration(minutes: 5))
      .millisecondsSinceEpoch,
  permissions: 0,
);

const _earlierMessages = [
  api.Message(
    id: 'm-1',
    channelId: 'c-general',
    authorId: 'user-grace',
    authorDisplayName: 'Grace Hopper',
    seq: 1,
    content: 'Welcome in, we are planning the next game night in here.',
    createdAt: 1753600000000,
    editedAt: null,
  ),
];

/// A new account on the channel shell: the controller's own check opens setup.
Future<void> _firstRun(
  WidgetTester tester,
  String viewport,
  String state, {
  required ReviewAct act,
  List<Override> extra = const [],
}) => reviewRoute(
  tester,
  surface: 'app-first-run-flow',
  state: state,
  viewport: viewport,
  route: '/channels',
  messages: _earlierMessages,
  overrides: [
    meProvider.overrideWith((ref) => _newcomer),
    firstRunClockProvider.overrideWithValue(() => harnessNow),
    firstRunInviterProvider.overrideWith((ref) => 'Grace Hopper'),
    serverInfoProvider.overrideWith(
      (ref) async => const api.Version(
        name: 'slim-m',
        version: '0.127.0',
        protocol: 1,
        spaceName: 'Lamplight',
        spaceDescription: 'A small place for the game night crowd.',
      ),
    ),
    spaceBannerBytesProvider.overrideWith((ref) async => null),
    // The real controller lists devices through a platform plugin a test has no host for.
    voiceControllerProvider.overrideWith(
      (ref) => SnapshotVoiceController(ref, const VoiceState()),
    ),
    notificationPreferenceProvider.overrideWith(
      (ref) async => api.NotificationPreference.mentions,
    ),
    pushControllerProvider.overrideWith(
      (ref) => FakePush(PushStatus.noTokenYet),
    ),
    ...extra,
  ],
  act: act,
);

Future<void> _untilSetupOpens(
  WidgetTester tester,
  ReviewHandles handles,
) async {
  for (var i = 0; i < 60; i++) {
    if (handles.ref.read(firstRunControllerProvider).active) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    handles.ref.read(firstRunControllerProvider).active,
    isTrue,
    reason: 'the due check never opened first-run setup',
  );
  await settleReview(tester);
}

ReviewAct _afterContinues(int taps, {String? heading}) =>
    (tester, handles) async {
      await _untilSetupOpens(tester, handles);
      for (var i = 0; i < taps; i++) {
        await tapLabel(tester, 'Continue');
      }
      if (heading != null) expect(find.text(heading), findsOneWidget);
    };

void main() {
  setUpAll(loadRealFonts);

  reviewCases(
    'app-first-run-flow',
    state: 'welcome',
    body: (tester, viewport) =>
        _firstRun(tester, viewport, 'welcome', act: _afterContinues(0)),
  );

  reviewCases(
    'app-first-run-flow',
    state: 'profile',
    body: (tester, viewport) => _firstRun(
      tester,
      viewport,
      'profile',
      act: _afterContinues(1, heading: 'Set up your profile'),
    ),
  );

  reviewCases(
    'app-first-run-flow',
    state: 'notifications',
    body: (tester, viewport) => _firstRun(
      tester,
      viewport,
      'notifications',
      act: _afterContinues(2, heading: 'Choose your notifications'),
    ),
  );

  reviewCases(
    'app-first-run-flow',
    state: 'voice',
    body: (tester, viewport) => _firstRun(
      tester,
      viewport,
      'voice',
      act: _afterContinues(3, heading: 'Check your voice'),
    ),
  );

  reviewCases(
    'app-first-run-flow',
    state: 'save-error',
    body: (tester, viewport) => _firstRun(
      tester,
      viewport,
      'save-error',
      extra: [_profileSaveRefused],
      act: (tester, handles) async {
        await _afterContinues(1, heading: 'Set up your profile')(
          tester,
          handles,
        );
        await typeInto(tester, 'Pronouns', 'she/her');
        await tapLabel(tester, 'Continue');
        expect(find.textContaining('Not saved'), findsOneWidget);
      },
    ),
  );
}
