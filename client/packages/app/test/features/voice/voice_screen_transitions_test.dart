// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice screen's stage transitions: a fast join failure was found to
/// hand off through a blank, unlabelled frame before landing on its real
/// error - reproduced here against the widget itself, not inferred from
/// reading the stage computation.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_connecting_loader.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_api.dart';
import '../../support/dead_voice_session.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _NoopSession extends DeadVoiceSession {
  @override
  bool get supportsParticipantVolume => true;

  @override
  bool get supportsScreenShareAudio => true;

  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();

  @override
  Stream<VoiceSessionState> get states => _states.stream;

  @override
  Stream<List<VoiceParticipant>> get participantChanges => _participants.stream;

  @override
  bool get screenShareSourcePickerUseful => true;

  @override
  Widget screenShareViewFor(String identity) =>
      SizedBox.shrink(key: Key('fake-share-view-$identity'));

  @override
  Widget cameraViewFor(String identity) =>
      SizedBox.shrink(key: Key('fake-camera-view-$identity'));

  @override
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) async => ScreenShareOutcome.started;

  @override
  Future<void> dispose() async {
    await _states.close();
    await _participants.close();
  }
}

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'a join still awaiting its token never shows the left-this-call screen',
    (tester) async {
      final tokenGate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          voiceRosterProvider.overrideWith(
            (ref, channelId) =>
                const Stream<List<VoiceRosterParticipant>>.empty(),
          ),
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          mockApiOverride((request) async {
            // Holds the join between joining being set and state moving off idle.
            await tokenGate.future;
            return http.Response(
              jsonEncode({
                'error': {'code': 'not_configured', 'message': 'no sfu'},
              }),
              501,
              headers: {'content-type': 'application/json'},
            );
          }),
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: _NoopSession()),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() {
        if (!tokenGate.isCompleted) tokenGate.complete();
      });

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), container),
      );
      // The post-frame callback calling join runs here, setting joining mid-flight.
      await tester.pump();
      await tester.pump();

      expect(
        find.text('You left this call.'),
        findsNothing,
        reason:
            'a join in flight is not a rejoin screen, however briefly the '
            'stage computation might disagree',
      );
      expect(find.byType(VoiceConnectingLoader), findsOneWidget);

      tokenGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('This Space has no voice configured.'), findsOneWidget);
    },
  );
}
