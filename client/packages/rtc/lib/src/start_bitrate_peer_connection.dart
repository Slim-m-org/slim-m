// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A peer connection that lets LiveKit's start bitrate hint reach the sender's estimator in a browser.
///
/// LiveKit writes the hint into the offer it sets locally, which Chrome ignores for sending, because it reads a sender's start bitrate from the remote description.
/// Repeating it on the answer that follows makes a share published into a running call ramp in
/// seconds instead of half a minute.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'answer_start_bitrate.dart';

/// Creates a peer connection, wrapped so offers' start bitrate hints are mirrored onto answers.
Future<rtc.RTCPeerConnection> createStartBitratePeerConnection(
  Map<String, dynamic> configuration, [
  Map<String, dynamic> constraints = const {},
]) async =>
    StartBitratePeerConnection(
      await rtc.createPeerConnection(configuration, constraints),
    );

/// Delegates to [inner], rewriting the remote answer when the last local offer carried a hint.
class StartBitratePeerConnection extends rtc.RTCPeerConnection {
  StartBitratePeerConnection(this.inner);

  final rtc.RTCPeerConnection inner;
  int? _pendingKbps;

  // The interface declares these parameters non-null with no default, so only the implementation can take a null.
  dynamic get _optional => inner;

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) {
    if (description.type == 'offer') {
      _pendingKbps = startBitrateIn(description.sdp ?? '') ?? _pendingKbps;
    }
    return inner.setLocalDescription(description);
  }

  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription description) {
    final kbps = _pendingKbps;
    final sdp = description.sdp;
    if (description.type != 'answer' || kbps == null || sdp == null) {
      return inner.setRemoteDescription(description);
    }
    _pendingKbps = null;
    return inner.setRemoteDescription(
      rtc.RTCSessionDescription(withStartBitrate(sdp, kbps), description.type),
    );
  }

  @override
  dynamic Function(rtc.RTCSignalingState state)? get onSignalingState =>
      inner.onSignalingState;
  @override
  set onSignalingState(dynamic Function(rtc.RTCSignalingState state)? value) =>
      inner.onSignalingState = value;
  @override
  dynamic Function(rtc.RTCPeerConnectionState state)? get onConnectionState =>
      inner.onConnectionState;
  @override
  set onConnectionState(
          dynamic Function(rtc.RTCPeerConnectionState state)? value) =>
      inner.onConnectionState = value;
  @override
  dynamic Function(rtc.RTCIceGatheringState state)? get onIceGatheringState =>
      inner.onIceGatheringState;
  @override
  set onIceGatheringState(
          dynamic Function(rtc.RTCIceGatheringState state)? value) =>
      inner.onIceGatheringState = value;
  @override
  dynamic Function(rtc.RTCIceConnectionState state)? get onIceConnectionState =>
      inner.onIceConnectionState;
  @override
  set onIceConnectionState(
          dynamic Function(rtc.RTCIceConnectionState state)? value) =>
      inner.onIceConnectionState = value;
  @override
  dynamic Function(rtc.RTCIceCandidate candidate)? get onIceCandidate =>
      inner.onIceCandidate;
  @override
  set onIceCandidate(dynamic Function(rtc.RTCIceCandidate candidate)? value) =>
      inner.onIceCandidate = value;
  @override
  dynamic Function(rtc.MediaStream stream)? get onAddStream =>
      inner.onAddStream;
  @override
  set onAddStream(dynamic Function(rtc.MediaStream stream)? value) =>
      inner.onAddStream = value;
  @override
  dynamic Function(rtc.MediaStream stream)? get onRemoveStream =>
      inner.onRemoveStream;
  @override
  set onRemoveStream(dynamic Function(rtc.MediaStream stream)? value) =>
      inner.onRemoveStream = value;
  @override
  dynamic Function(rtc.MediaStream stream, rtc.MediaStreamTrack track)?
      get onAddTrack => inner.onAddTrack;
  @override
  set onAddTrack(
    dynamic Function(rtc.MediaStream stream, rtc.MediaStreamTrack track)? value,
  ) =>
      inner.onAddTrack = value;
  @override
  dynamic Function(rtc.MediaStream stream, rtc.MediaStreamTrack track)?
      get onRemoveTrack => inner.onRemoveTrack;
  @override
  set onRemoveTrack(
    dynamic Function(rtc.MediaStream stream, rtc.MediaStreamTrack track)? value,
  ) =>
      inner.onRemoveTrack = value;
  @override
  dynamic Function(rtc.RTCDataChannel channel)? get onDataChannel =>
      inner.onDataChannel;
  @override
  set onDataChannel(dynamic Function(rtc.RTCDataChannel channel)? value) =>
      inner.onDataChannel = value;
  @override
  dynamic Function()? get onRenegotiationNeeded => inner.onRenegotiationNeeded;
  @override
  set onRenegotiationNeeded(dynamic Function()? value) =>
      inner.onRenegotiationNeeded = value;
  @override
  dynamic Function(rtc.RTCTrackEvent event)? get onTrack => inner.onTrack;
  @override
  set onTrack(dynamic Function(rtc.RTCTrackEvent event)? value) =>
      inner.onTrack = value;

  @override
  rtc.RTCSignalingState? get signalingState => inner.signalingState;
  @override
  rtc.RTCIceGatheringState? get iceGatheringState => inner.iceGatheringState;
  @override
  rtc.RTCIceConnectionState? get iceConnectionState => inner.iceConnectionState;
  @override
  rtc.RTCPeerConnectionState? get connectionState => inner.connectionState;
  @override
  Map<String, dynamic> get getConfiguration => inner.getConfiguration;

  @override
  Future<rtc.RTCSignalingState?> getSignalingState() =>
      inner.getSignalingState();
  @override
  Future<rtc.RTCIceGatheringState?> getIceGatheringState() =>
      inner.getIceGatheringState();
  @override
  Future<rtc.RTCIceConnectionState?> getIceConnectionState() =>
      inner.getIceConnectionState();
  @override
  Future<rtc.RTCPeerConnectionState?> getConnectionState() =>
      inner.getConnectionState();
  @override
  Future<void> dispose() => inner.dispose();
  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) =>
      inner.setConfiguration(configuration);
  @override
  Future<rtc.RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) =>
      inner.createOffer(constraints ?? const {});
  @override
  Future<rtc.RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) =>
      inner.createAnswer(constraints ?? const {});
  @override
  Future<void> addStream(rtc.MediaStream stream) => inner.addStream(stream);
  @override
  Future<void> removeStream(rtc.MediaStream stream) =>
      inner.removeStream(stream);
  @override
  Future<rtc.RTCSessionDescription?> getLocalDescription() =>
      inner.getLocalDescription();
  @override
  Future<rtc.RTCSessionDescription?> getRemoteDescription() =>
      inner.getRemoteDescription();
  @override
  Future<void> addCandidate(rtc.RTCIceCandidate candidate) =>
      inner.addCandidate(candidate);
  @override
  Future<List<rtc.StatsReport>> getStats([rtc.MediaStreamTrack? track]) =>
      inner.getStats(track);
  @override
  List<rtc.MediaStream?> getLocalStreams() => inner.getLocalStreams();
  @override
  List<rtc.MediaStream?> getRemoteStreams() => inner.getRemoteStreams();
  @override
  Future<rtc.RTCDataChannel> createDataChannel(
    String label,
    rtc.RTCDataChannelInit dataChannelDict,
  ) =>
      inner.createDataChannel(label, dataChannelDict);
  @override
  Future<void> restartIce() => inner.restartIce();
  @override
  Future<void> close() => inner.close();
  @override
  rtc.RTCDTMFSender createDtmfSender(rtc.MediaStreamTrack track) =>
      inner.createDtmfSender(track);
  @override
  Future<List<rtc.RTCRtpSender>> getSenders() => inner.getSenders();
  @override
  Future<List<rtc.RTCRtpReceiver>> getReceivers() => inner.getReceivers();
  @override
  Future<List<rtc.RTCRtpTransceiver>> getTransceivers() =>
      inner.getTransceivers();
  @override
  Future<rtc.RTCRtpSender> addTrack(
    rtc.MediaStreamTrack track, [
    rtc.MediaStream? stream,
  ]) async =>
      await _optional.addTrack(track, stream) as rtc.RTCRtpSender;
  @override
  Future<bool> removeTrack(rtc.RTCRtpSender sender) =>
      inner.removeTrack(sender);
  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({
    rtc.MediaStreamTrack? track,
    rtc.RTCRtpMediaType? kind,
    rtc.RTCRtpTransceiverInit? init,
  }) async =>
      await _optional.addTransceiver(track: track, kind: kind, init: init)
          as rtc.RTCRtpTransceiver;
}
