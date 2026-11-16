// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Silencing the loopback's far end must not switch off the capture it reads,
/// and neither end may open a TCP listener.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/rtc.dart'
    show AudioDevice, AudioDeviceSwitching, AudioDevices, PulseAudio;
import 'package:slimm_rtc/src/mic_preview_loopback.dart';

class _Track implements rtc.MediaStreamTrack {
  final enabledWrites = <bool>[];

  @override
  String get kind => 'audio';

  @override
  String get id => 'shared-track-id';

  @override
  set enabled(bool value) => enabledWrites.add(value);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoDevices implements AudioDevices {
  @override
  Future<List<AudioDevice>> inputs() async => const [];

  @override
  Future<List<AudioDevice>> outputs() async => const [];

  @override
  Future<AudioDevice?> systemDefaultInput() async => null;

  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;

  @override
  Stream<void> get onChange => const Stream.empty();
}

class _Peer implements rtc.RTCPeerConnection {
  @override
  Future<rtc.RTCSessionDescription> createOffer(
          [Map<String, dynamic> constraints = const {}]) async =>
      rtc.RTCSessionDescription('offer-sdp', 'offer');

  @override
  Future<rtc.RTCSessionDescription> createAnswer(
          [Map<String, dynamic> constraints = const {}]) async =>
      rtc.RTCSessionDescription('answer-sdp', 'answer');

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription d) async {}

  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription d) async {}

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void _mockWebRtcChannel() {
  const channel = MethodChannel('FlutterWebRTC.Method');
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    channel,
    (call) async => call.method == 'getUserMedia'
        ? {'streamId': 'preview', 'audioTracks': [], 'videoTracks': []}
        : null,
  );
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('both ends of the loopback gather no TCP candidates', () async {
    _mockWebRtcChannel();
    final configurations = <Map<String, dynamic>>[];
    final source = LoopbackMicSource(
      AudioDeviceSwitching(_NoDevices(), pulse: PulseAudio.inert()),
      createPeer: (configuration) async {
        configurations.add(configuration);
        return _Peer();
      },
    );

    await source.open(null);
    await source.close();

    expect(configurations, hasLength(2));
    for (final configuration in configurations) {
      expect(configuration['tcpCandidatePolicy'], 'disabled',
          reason: 'a TCP candidate listens, and Windows asks to allow it');
    }
  });

  test('silences the received track by volume and never disables it', () async {
    final calls = <MethodCall>[];
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Method'), null));
    final track = _Track();

    await silenceLoopbackTrack(track);

    expect(track.enabledWrites, isEmpty,
        reason: 'both ends share the track id, so this would stop the capture');
    expect(calls.map((c) => c.method), contains('setVolume'));
    expect(
      (calls.firstWhere((c) => c.method == 'setVolume').arguments
          as Map)['volume'],
      0.0,
    );
  });
}
