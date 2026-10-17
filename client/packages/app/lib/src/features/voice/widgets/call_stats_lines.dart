// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text the call stats panel shows for one sample.
///
/// Plain strings in and out so the wording is testable without a widget tree.
library;

import 'package:slimm_rtc/rtc.dart';

/// The heading of a sample's card.
String callStatsTitle(VideoStatsSample s) {
  final what = s.source == CallStatsSource.camera ? 'camera' : 'screen share';
  return s.local ? 'You, sending $what' : '${s.name}, $what';
}

/// The lines for one stream: size and rate first, then the codec, then what
/// is going wrong.
List<String> callStatsStreamLines(VideoStreamStats s, {required bool local}) {
  final size = s.width == null || s.height == null
      ? 'unknown size'
      : '${s.width}x${s.height}';
  final head = [
    if (s.rid != null) 'layer ${s.rid}',
    '$size at ${_fps(s.fps)}',
    _rate(s),
  ].join('  ');
  final codec = [
    if (s.codec != null) s.codec!,
    if (s.implementation != null) s.implementation!,
    if (s.powerEfficient == true) 'hardware',
    if (s.active == false) 'not sending',
  ].join('  ');
  final trouble = local ? _sendTrouble(s) : _receiveTrouble(s);
  return [head, if (codec.isNotEmpty) codec, if (trouble.isNotEmpty) trouble];
}

/// The network path line, or null when the report had none.
String? callStatsTransportLine(TransportStats? t) {
  if (t == null) return null;
  final path = [
    if (t.localType != null) t.localType!,
    if (t.protocol != null) t.protocol!,
    if (t.relayed) 'relayed',
  ].join(' ');
  return [
    if (t.rttMs != null) '${t.rttMs!.round()} ms round trip',
    if (t.availableOutgoingBps != null)
      '${_mbps(t.availableOutgoingBps!)} available to send',
    if (path.isNotEmpty) path,
  ].join('  ');
}

String _fps(double? fps) => fps == null ? '? fps' : '${fps.round()} fps';

String _rate(VideoStreamStats s) {
  final measured = s.bitrateBps == null ? '...' : _mbps(s.bitrateBps!);
  final target = s.targetBitrateBps == null
      ? ''
      : ' of ${_mbps(s.targetBitrateBps!)}';
  return '$measured$target';
}

String _mbps(double bps) => '${(bps / 1e6).toStringAsFixed(2)} Mbps';

String _sendTrouble(VideoStreamStats s) {
  final reason = s.limitationReason;
  return [
    if (reason != null && reason != 'none') 'limited by $reason',
    if ((s.limitationResolutionChanges ?? 0) > 0)
      '${s.limitationResolutionChanges} size changes',
    if ((s.pliCount ?? 0) > 0) '${s.pliCount} keyframe requests',
  ].join('  ');
}

String _receiveTrouble(VideoStreamStats s) => [
  if ((s.freezeCount ?? 0) > 0)
    '${s.freezeCount} freezes (${(s.freezeSeconds ?? 0).toStringAsFixed(1)} s)',
  if ((s.framesDropped ?? 0) > 0) '${s.framesDropped} frames dropped',
  if ((s.packetsLost ?? 0) > 0) '${s.packetsLost} packets lost',
  if (s.jitterMs != null) 'jitter ${s.jitterMs!.round()} ms',
].join('  ');
