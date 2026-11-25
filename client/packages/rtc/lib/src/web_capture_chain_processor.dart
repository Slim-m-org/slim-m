// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The LiveKit side of the browser capture chain: attaches the chain to a
/// microphone track, falls back to the raw track, and keeps the sender on the
/// processed one. Free of browser types so a VM test can drive it.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

/// Runs a LiveKit microphone track through the chain before it is published.
class WebCaptureProcessor
    implements lk.TrackProcessor<lk.AudioProcessorOptions> {
  WebCaptureProcessor({
    required this.name,
    required this.attach,
    required this.detach,
    this.chainFailures,
  });

  @override
  final String name;

  /// Gives back the chain's output for a microphone track, or the track itself when the chain is unavailable.
  final Future<rtc.MediaStreamTrack> Function(rtc.MediaStreamTrack track)
      attach;

  /// Releases the chain from [processed], the output [attach] gave.
  final Future<void> Function(rtc.MediaStreamTrack processed) detach;

  /// Fires when the chain dies after it attached, as when its worklet throws; the processed track is silent from then on.
  final Stream<void>? chainFailures;

  rtc.MediaStreamTrack? _processed;
  rtc.MediaStreamTrack? _raw;
  StreamSubscription<void>? _failures;
  lk.Room? _room;

  @override
  rtc.MediaStreamTrack? get processedTrack => _processed;

  @override
  Future<void> init(lk.AudioProcessorOptions options) async {
    await _failures?.cancel();
    _raw = options.track;
    final processed = await attach(options.track);
    _processed = identical(processed, options.track) ? null : processed;
    _failures = chainFailures?.listen((_) => unawaited(_fallBackToRaw()));
    await _sendProcessed();
  }

  @override
  Future<void> restart(lk.AudioProcessorOptions options) => init(options);

  @override
  Future<void> destroy() async {
    await _failures?.cancel();
    _failures = null;
    final processed = _processed;
    _processed = null;
    if (processed == null) return;
    await detach(processed);
    await processed.stop();
  }

  Future<void> _fallBackToRaw() async {
    final processed = _processed;
    final raw = _raw;
    if (processed == null || raw == null) return;
    _processed = null;
    await _replaceSenderTrack(raw);
    await detach(processed);
    await processed.stop();
  }

  @override
  Future<void> onPublish(lk.Room room) async => _room = room;

  @override
  Future<void> onUnpublish() async => _room = null;

  /// `LocalTrack.restartTrack` hands the sender the raw capture before it sets
  /// the processor again, so a restarted track would go out unprocessed.
  Future<void> _sendProcessed() async {
    final processed = _processed;
    if (processed != null) await _replaceSenderTrack(processed);
  }

  Future<void> _replaceSenderTrack(rtc.MediaStreamTrack next) async {
    final room = _room;
    if (room == null) return;
    for (final publication
        in room.localParticipant?.audioTrackPublications ?? const []) {
      final track = publication.track;
      if (track == null || !identical(track.processor, this)) continue;
      final sender = track.sender;
      if (sender != null && sender.track?.id != next.id) {
        await sender.replaceTrack(next);
      }
    }
  }
}
