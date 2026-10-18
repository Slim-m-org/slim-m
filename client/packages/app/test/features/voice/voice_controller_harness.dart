// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the two suites that drive a [VoiceController]: the
/// controller's own behaviour, and the iOS broadcast handoff.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. Both
/// suites need the same hand-driven [VoiceSession], the same token endpoint
/// and the same provider wiring around them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_auto_rejoin.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'fake_voice_session.dart';

export 'fake_voice_session.dart';

const tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Answers the token and heartbeat endpoints however the test asks.
///
/// [sfuUrl] defaults to a wss address, the only shape the server's own
/// config validation and most tests need; the plain-ws suite overrides it.
/// [onRequest], when given, is called with every request this client
/// answers, so a test can count or inspect heartbeat calls without a second
/// mock layered on top. The whole request, not just the url: a POST
/// heartbeat and the DELETE that forgets one on a clean leave share a path,
/// and only the method tells them apart.
/// [failHeartbeat] models a heartbeat that cannot reach the server while the
/// media transport stays up entirely, the case
/// `voice_call_heartbeat_test.dart`'s lag tests need: a POST failure with no
/// change to how `/voice/token` answers.
http.Client voiceApi({
  int status = 200,
  bool canPublish = true,
  String sfuUrl = 'wss://sfu.example.com',
  bool failHeartbeat = false,
  int? callAgeMs,
  void Function(http.Request request)? onRequest,
}) {
  return MockClient((request) async {
    onRequest?.call(request);
    if (request.url.path.endsWith('/voice/heartbeat')) {
      if (failHeartbeat && request.method == 'POST') {
        return http.Response('', 503);
      }
      return http.Response('', 204);
    }
    if (request.url.path.endsWith('/voice/roster')) {
      return http.Response('{"participants":[],"call_age_ms":$callAgeMs}', 200);
    }
    if (!request.url.path.endsWith('/voice/token')) {
      return http.Response('{}', 404);
    }
    if (status != 200) {
      return http.Response(
        jsonEncode({
          'error': {'code': 'nope', 'message': 'refused'},
        }),
        status,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode({
        'url': sfuUrl,
        'room': 'channel-1',
        'token': 'jwt',
        'expires_at': 0,
        'can_publish': canPublish,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// A [VoiceController] pinned to [fixed], for a test that renders against a
/// known [VoiceState] without driving a real join through it. `state` is
/// only settable from within a [VoiceController] subclass, never from
/// outside one, which is why this exists rather than a plain field assign.
class FixedVoiceController extends VoiceController {
  FixedVoiceController(super.ref, VoiceState fixed)
    : super(session: FakeSession()) {
    state = fixed;
  }
}

/// Records each join and reports the call as connected.
class RecordingVoiceController extends VoiceController {
  RecordingVoiceController(super.ref) : super(session: FakeSession());

  final joins = <String>[];

  @override
  Future<void> join(String channelId) async {
    joins.add(channelId);
    state = VoiceState(
      state: VoiceSessionState.connected,
      channelId: channelId,
    );
  }
}

/// Owns the container so a suite can tear it down in one place.
class VoiceHarness {
  ProviderContainer? _container;

  /// For a widget test to wrap in `UncontrolledProviderScope`; only valid
  /// after [controllerWith] has built one.
  ProviderContainer get container => _container!;

  void dispose() {
    AppLog.install(null);
    _container?.dispose();
  }

  /// What the controller recorded for the user to read back in settings.
  List<DiagnosticEvent> log(VoiceController _) =>
      _container!.read(debugLogProvider);

  /// The controller as the app builds it, with only the network and the SFU
  /// swapped: a real session, a real [SlimmApi], and the same provider wiring.
  ///
  /// [now], when given, stands in for `DateTime.now()` everywhere the
  /// controller reads the clock - the call recap's duration math, so a test
  /// can advance it by hand rather than racing real wall time.
  /// [extraOverrides] append onto the fixed list above, for a caller (a
  /// widget test) that also needs to stub something like `voiceRosterProvider`.
  VoiceController controllerWith(
    FakeSession session,
    http.Client client, {
    Duration broadcastStartTimeout = const Duration(seconds: 30),
    Duration voiceHeartbeatInterval = const Duration(seconds: 15),
    List<Duration> autoRejoinDelays = VoiceAutoRejoin.defaultDelays,
    CallLifecycleChannel? callLifecycle,
    DateTime Function()? now,
    List<Override> extraOverrides = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(api.close);
          return api;
        }),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(
            ref,
            session: session,
            broadcastStartTimeout: broadcastStartTimeout,
            voiceHeartbeatInterval: voiceHeartbeatInterval,
            autoRejoinDelays: autoRejoinDelays,
            callLifecycle: callLifecycle,
            now: now,
          ),
        ),
        ...extraOverrides,
      ],
    );
    _container = container;
    AppLog.install(container.read(debugLogProvider.notifier));
    return container.read(voiceControllerProvider.notifier);
  }
}
