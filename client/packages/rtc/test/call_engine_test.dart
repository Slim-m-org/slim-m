// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the call's engine does about a publish answer or an offer lost with the signal socket, and a leave mid-restart.
library;

// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/core/transport.dart' as lk_transport;
// ignore: implementation_imports
import 'package:livekit_client/src/internal/events.dart' as lk_events;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
// ignore: implementation_imports
import 'package:livekit_client/src/types/internal.dart' as lk_internal;
import 'package:slimm_rtc/src/call_engine.dart';
import 'package:slimm_rtc/src/start_bitrate_room.dart';

class _Track implements rtc.MediaStreamTrack {
  _Track(this.id);

  @override
  final String id;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sender implements rtc.RTCRtpSender {
  _Sender(String? trackId) : track = trackId == null ? null : _Track(trackId);

  @override
  final rtc.MediaStreamTrack? track;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A publisher connection that records what was taken off it and what was offered.
class _Publisher implements rtc.RTCPeerConnection {
  final attached = <_Sender>[];
  final removed = <String?>[];
  var offers = 0;
  rtc.RTCSignalingState state = rtc.RTCSignalingState.RTCSignalingStateStable;

  @override
  Future<List<rtc.RTCRtpSender>> getSenders() async => [...attached];

  @override
  Future<bool> removeTrack(rtc.RTCRtpSender sender) async {
    removed.add(sender.track?.id);
    attached.remove(sender);
    return true;
  }

  @override
  Future<rtc.RTCSignalingState?> getSignalingState() async => state;

  @override
  Future<rtc.RTCSessionDescription?> getLocalDescription() async =>
      rtc.RTCSessionDescription('v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n', 'offer');

  @override
  Future<rtc.RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    offers++;
    return rtc.RTCSessionDescription('v=0\r\n', 'offer');
  }

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription d) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A full reconnect whose new signal connection has not answered yet, until [release].
class _RestartThatHangs extends CallEngine {
  _RestartThatHangs() : super(roomOptions: const lk.RoomOptions());

  final restarting = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> restartConnection({String? regionUrl}) async {
    restarting.complete();
    await release.future;
    throw lk.ConnectException(
      'Timed out waiting for SignalJoinResponseEvent',
      reason: lk.ConnectionErrorReason.Timeout,
    );
  }
}

Future<CallEngine> _engineOn(_Publisher pc) async {
  final engine = CallEngine(
    roomOptions: const lk.RoomOptions(),
    connectOptions: const lk.ConnectOptions(timeouts: _quickPublish),
    stuckOfferGrace: const Duration(milliseconds: 30),
    signalLive: () => true,
  );
  engine.publisher = await lk_transport.Transport.create(
    (configuration, [constraints = const {}]) async => pc,
    connectOptions: engine.connectOptions,
  );
  engine.publisher!.onOffer = (_) {};
  return engine;
}

/// The stock timeouts with the 10 s wait for a publish answer cut short.
const _quickPublish = lk.Timeouts(
  connection: Duration(seconds: 10),
  debounce: Duration(milliseconds: 20),
  publish: Duration(milliseconds: 30),
  subscribe: Duration(seconds: 10),
  peerConnection: Duration(seconds: 10),
  iceRestart: Duration(seconds: 10),
);

lk_rtc.AddTrackRequest _microphone(String cid) => lk_rtc.AddTrackRequest(
      cid: cid,
      type: lk_models.TrackType.AUDIO,
      source: lk_models.TrackSource.MICROPHONE,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every call room runs on the call engine', () {
    final room = buildRoomWithStartBitrate(const lk.RoomOptions());
    expect(room.engine, isA<CallEngine>());
  });

  test(
      'a publish whose answer never comes takes its sender off the publisher '
      'and offers again', () async {
    final pc = _Publisher()
      ..attached.addAll([_Sender('camera'), _Sender('mic'), _Sender(null)]);
    final engine = await _engineOn(pc);

    await expectLater(
      engine.addTrack(_microphone('mic')),
      throwsA(isA<lk.TrackPublishException>()),
    );

    expect(pc.removed, ['mic'],
        reason: 'the sender was still sending with no publication to mute');
    expect(pc.attached.map((s) => s.track?.id), ['camera', null]);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (pc.offers == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(pc.offers, 1,
        reason: 'the server only drops the track once it is offered again');
  });

  test('a resume with an offer still unanswered asks for a restart instead',
      () async {
    final pc = _Publisher()
      ..state = rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer;
    final engine = await _engineOn(pc);

    await expectLater(
      engine.resumeConnection(lk_internal.ClientDisconnectReason.signal),
      throwsA(isA<lk.NegotiationError>()),
    );
    expect(engine.fullReconnectOnNext, isTrue);
  });

  test(
      'an offer still out after a resume finished restarts the connection, '
      'since nothing will ever answer it', () async {
    final pc = _Publisher();
    final engine = await _engineOn(pc);
    addTearDown(engine.dispose);
    final attempts = <lk_events.EngineAttemptReconnectEvent>[];
    engine.events.on<lk_events.EngineAttemptReconnectEvent>(attempts.add);

    pc.state = rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer;
    engine.events.emit(const lk_events.EngineResumedEvent());
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (attempts.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(attempts, isNotEmpty);
    expect(
        engine.fullReconnectOnNext || engine.isFullReconnectInProgress, isTrue);
  });

  test(
      'a leave that closes the engine during a full reconnect still ends the '
      'call, instead of leaving it on screen with no connection', () async {
    final engine = _RestartThatHangs();
    final room = lk.Room(roomOptions: const lk.RoomOptions(), engine: engine);
    final ended = <lk.RoomDisconnectedEvent>[];
    final cancel = room.events.on<lk.RoomDisconnectedEvent>(ended.add);
    addTearDown(cancel);

    engine.fullReconnectOnNext = true;
    final attempt = engine.attemptReconnect(
      lk_internal.ClientDisconnectReason.signal,
    );
    await engine.restarting.future;
    await engine.disconnect(reason: lk.DisconnectReason.duplicateIdentity);
    await pumpEventQueue();

    expect(ended.map((e) => e.reason), [lk.DisconnectReason.duplicateIdentity]);
    engine.release.complete();
    await attempt;
  });

  test('an offer answered after a resume leaves the connection alone',
      () async {
    final pc = _Publisher();
    final engine = await _engineOn(pc);
    addTearDown(engine.dispose);
    final attempts = <lk_events.EngineAttemptReconnectEvent>[];
    engine.events.on<lk_events.EngineAttemptReconnectEvent>(attempts.add);

    pc.state = rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer;
    engine.events.emit(const lk_events.EngineResumedEvent());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    pc.state = rtc.RTCSignalingState.RTCSignalingStateStable;
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(attempts, isEmpty);
    expect(engine.fullReconnectOnNext, isFalse);
  });
}
