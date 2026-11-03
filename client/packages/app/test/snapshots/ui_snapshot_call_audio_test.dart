// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call-audio surfaces (decision 0105): the banner in each state, the
/// prompt everyone else gets, the start control and its sheet, and the admin
/// card, at desktop and phone width in both themes. PNGs are written only
/// under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart'
    show myVisibleChannelsProvider;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_call_audio_card.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_audio_banner.dart';
import 'package:slimm_app/src/features/voice/widgets/call_audio_prompt.dart';
import 'package:slimm_app/src/features/voice/widgets/call_audio_start.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'package:slimm_app/src/providers/sync_controller.dart';

import '../support/fake_sync.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

Map<String, dynamic> _session({
  required bool on,
  List<String> pending = const [],
}) => {
  'module_id': 'transcript',
  'module_name': 'Transcript',
  'purpose': 'Writes down what is said.',
  'keeps': 'The text, for 30 days.',
  'status': on ? 'on' : 'asking',
  'asked_by': 'asker',
  'included': const ['asker'],
  'pending': pending,
  'expires_at_ms': 4102444800000,
  'full': false,
};

const _startable = [
  {
    'module_id': 'transcript',
    'module_name': 'Transcript',
    'purpose': 'Writes down what is said.',
    'keeps': 'The text, for 30 days.',
  },
];

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _mount(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  required String name,
  required Widget Function() child,
  required String channel,
  Map<String, dynamic>? session,
  List<Map<String, dynamic>> startable = const [],
  Future<void> Function()? before,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final container = ProviderContainer(
    overrides: [
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      liveEventsProvider.overrideWithValue(events.stream),
      voiceFlagsProvider.overrideWithValue(VoiceFlags(channelId: channel)),
      userProfileProvider.overrideWith((ref, id) async => null),
      myVisibleChannelsProvider.overrideWith(
        (ref) async => [
          const api.Channel(
            id: 'v1',
            name: 'Lounge',
            kind: 'voice',
            createdAt: 0,
          ),
          const api.Channel(
            id: 'v2',
            name: 'Game night',
            kind: 'voice',
            createdAt: 0,
          ),
          const api.Channel(
            id: 't1',
            name: 'general',
            kind: 'text',
            createdAt: 0,
          ),
        ],
      ),
      apiProvider.overrideWith((ref) {
        final client = testApi((request) async {
          if (request.url.path.endsWith('/call-audio-channels')) {
            return _json({
              'channel_ids': ['v1'],
            });
          }
          return _json({'session': session, 'startable': startable});
        }, session: api.SessionStore(tokens: _tokens));
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(sessionProvider).set(_tokens);
  final tokens = brightness == Brightness.dark
      ? AppTokens.dark
      : AppTokens.light;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness, tokens),
          home: Scaffold(
            backgroundColor: tokens.surfaceBase,
            body: Stack(children: [child()]),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  if (before != null) await before();
  await tester.pump(const Duration(milliseconds: 350));
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
}

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'desktop': Size(1100, 360), 'phone': Size(390, 640)};
  for (final MapEntry(key: width, value: size) in sizes.entries) {
    for (final brightness in Brightness.values) {
      final suffix = '$width-${brightness.name}';

      final banner = <(String, bool, List<String>)>[
        ('on', true, const []),
        ('asking-me', true, const ['me']),
        ('waiting', false, const ['other']),
      ];
      for (final (label, on, pending) in banner) {
        final name = 'call-audio-banner-$label-$suffix';
        testWidgets(name, (tester) async {
          await _mount(
            tester,
            size: size,
            brightness: brightness,
            name: name,
            channel: 'c1',
            session: _session(on: on, pending: pending),
            child: () => const Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.s16),
                child: CallAudioBanner(channelId: 'c1'),
              ),
            ),
          );
        });
      }

      final promptName = 'call-audio-prompt-$suffix';
      testWidgets(promptName, (tester) async {
        await _mount(
          tester,
          size: size,
          brightness: brightness,
          name: promptName,
          channel: 'c1',
          session: _session(on: false, pending: const ['me', 'other']),
          child: () => const CallAudioPrompt(),
        );
      });

      final startName = 'call-audio-start-$suffix';
      testWidgets(startName, (tester) async {
        await _mount(
          tester,
          size: size,
          brightness: brightness,
          name: startName,
          channel: 'c1',
          startable: _startable,
          child: () => const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.s16),
              child: CallAudioStartControl(channelId: 'c1'),
            ),
          ),
          before: () async {
            await tester.tap(find.byKey(CallAudioStartControl.buttonKey));
            await tester.pump(const Duration(milliseconds: 400));
          },
        );
      });

      final cardName = 'call-audio-admin-card-$suffix';
      testWidgets(cardName, (tester) async {
        await _mount(
          tester,
          size: size,
          brightness: brightness,
          name: cardName,
          channel: 'c1',
          child: () => const Padding(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: DockCallAudioCard(
              moduleId: 'transcript',
              moduleName: 'Transcript',
            ),
          ),
        );
      });
    }
  }
}
