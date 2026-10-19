// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone preview's capture: libwebrtc only runs its audio processing
/// while a track is being sent, so the track is sent to a second connection in
/// this process and nobody hears it.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'audio_device_switching.dart';
import 'audio_devices.dart';
import 'input_gate.dart' show kInputFloorDb, supportsInputGate;
import 'mic_preview.dart';
import 'mic_recovery.dart' show senderLevelToDb;

class LoopbackMicSource implements MicPreviewSource {
  LoopbackMicSource(this._switching);

  final AudioDeviceSwitching _switching;
  rtc.MediaStream? _stream;
  rtc.RTCPeerConnection? _sender;
  rtc.RTCPeerConnection? _receiver;
  bool _opened = false;

  /// Process-wide, so an old preview's close finishes before a new one opens.
  static Future<void> _turn = Future<void>.value();

  static Future<void> _serial(Future<void> Function() job) {
    final run = _turn.then((_) => job());
    _turn = run.then((_) {}, onError: (_) {});
    return run;
  }

  @override
  Future<void> open(String? deviceId) => _serial(() => _open(deviceId));

  @override
  Future<void> close() => _serial(_close);

  Future<void> _open(String? deviceId) async {
    if (_opened) await _close();
    _opened = true;
    final constraints = _switching.previewCaptureOptions(
      await _switching.pluggedInputId(deviceId),
    );
    final stream = _stream = await rtc.navigator.mediaDevices.getUserMedia({
      'audio': constraints.toMediaConstraintsMap(),
      'video': false,
    });
    final sender = _sender = await rtc.createPeerConnection({});
    final receiver = _receiver = await rtc.createPeerConnection({});
    sender.onIceCandidate = (c) => unawaited(receiver.addCandidate(c));
    receiver.onIceCandidate = (c) => unawaited(sender.addCandidate(c));
    receiver.onTrack = (event) => unawaited(_silence(event.track));
    for (final track in stream.getAudioTracks()) {
      await sender.addTrack(track, stream);
    }
    final offer = await sender.createOffer();
    await sender.setLocalDescription(offer);
    await receiver.setRemoteDescription(offer);
    final answer = await receiver.createAnswer();
    await receiver.setLocalDescription(answer);
    await sender.setRemoteDescription(answer);
    await _routeWhenStreaming(deviceId);
  }

  /// The sound server stream only exists once the track is sending, so the
  /// move is tried again after it has had a moment to open.
  Future<void> _routeWhenStreaming(String? deviceId) async {
    final id = await _switching.pluggedInputId(deviceId);
    for (final wait in const [Duration.zero, Duration(milliseconds: 700)]) {
      await Future<void>.delayed(wait);
      if (!_opened) return;
      await _switching.routePreviewInput(id);
    }
  }

  /// The far end must never reach the speakers.
  Future<void> _silence(rtc.MediaStreamTrack track) async {
    track.enabled = false;
    try {
      await rtc.Helper.setVolume(0, track);
    } on Object catch (error, stack) {
      // The web has no playout without an element, and a disabled track is silent already.
      AppLog.swallowed(
          LogTag.voice, 'Could not mute the loopback', error, stack);
    }
  }

  @override
  Future<({double levelDb, bool voice})?> read() async {
    if (supportsInputGate) return _readGate();
    final sender = _sender;
    if (sender == null) return null;
    for (final report in await sender.getStats()) {
      if (report.type != 'media-source') continue;
      final level = report.values['audioLevel'];
      if (level is num) {
        return (levelDb: senderLevelToDb(level.toDouble()), voice: false);
      }
    }
    return null;
  }

  Future<({double levelDb, bool voice})?> _readGate() async {
    final raw = await rtc.WebRTC.invokeMethod<Object?, Object?>('getInputGate');
    if (raw is! Map) return null;
    return (
      levelDb: (raw['levelDb'] as num?)?.toDouble() ?? kInputFloorDb,
      voice: raw['voice'] == true,
    );
  }

  Future<void> _close() async {
    _opened = false;
    final sender = _sender;
    final receiver = _receiver;
    final stream = _stream;
    _sender = _receiver = _stream = null;
    for (final track in stream?.getAudioTracks() ?? const []) {
      await track.stop();
    }
    await sender?.close();
    await receiver?.close();
    await stream?.dispose();
  }
}

/// A preview over the real microphone, on this host's own device list.
MicPreview systemMicPreview() => MicPreview(
      source: LoopbackMicSource(
        AudioDeviceSwitching(HardwareAudioDevices()),
      ),
    );
