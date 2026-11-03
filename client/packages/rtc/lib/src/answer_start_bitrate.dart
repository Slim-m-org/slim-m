// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Carries the `x-google-start-bitrate` hint from an offer onto its answer.
///
/// libwebrtc takes a sender's start bitrate from the codec parameters of the
/// remote description, so a hint only in our own offer never seeds the estimator.
library;

const _hintKey = 'x-google-start-bitrate';
final _hint = RegExp('$_hintKey=(\\d+)');
final _rtpmap = RegExp(r'^a=rtpmap:(\d+) ([^/\s]+)');
final _fmtp = RegExp(r'^a=fmtp:(\d+) (.*)$');
const _notMedia = {'rtx', 'red', 'ulpfec', 'flexfec-03'};

/// The largest start bitrate, in kbps, written on a video codec of [sdp], or null when none is.
int? startBitrateIn(String sdp) {
  int? largest;
  var video = false;
  for (final line in sdp.split('\r\n')) {
    if (line.startsWith('m=')) video = line.startsWith('m=video');
    final value = video ? _hint.firstMatch(line)?.group(1) : null;
    final kbps = value == null ? null : int.tryParse(value);
    if (kbps != null && (largest == null || kbps > largest)) largest = kbps;
  }
  return largest;
}

/// The most the answer may ask the estimator to start at, in kbps.
///
/// LiveKit's own hint for a share is 0.9 of the layer sum, about 9 Mbps; on a link well under that the burst loses packets and freezes the viewer for seconds.
const maxAnswerStartKbps = 3000;

/// [answer] with every video media codec asking to start at [requestedKbps], capped at [maxAnswerStartKbps].
String withStartBitrate(String answer, int requestedKbps) {
  final kbps =
      requestedKbps < maxAnswerStartKbps ? requestedKbps : maxAnswerStartKbps;
  final lines = answer.split('\r\n');
  final withFmtp = _payloadsWithFmtp(lines);
  final out = <String>[];
  var video = false;
  for (final line in lines) {
    if (line.startsWith('m=')) video = line.startsWith('m=video');
    final fmtp = video ? _fmtp.firstMatch(line) : null;
    if (fmtp != null && !_isRepair(fmtp.group(2)!)) {
      out.add(_withHint(line, kbps));
      continue;
    }
    out.add(line);
    final map = video ? _rtpmap.firstMatch(line) : null;
    if (map != null &&
        !_notMedia.contains(map.group(2)!.toLowerCase()) &&
        !withFmtp.contains(map.group(1))) {
      out.add('a=fmtp:${map.group(1)} $_hintKey=$kbps');
    }
  }
  return out.join('\r\n');
}

bool _isRepair(String params) => params.startsWith('apt=');

String _withHint(String line, int kbps) =>
    line.contains(_hintKey) ? line : '$line;$_hintKey=$kbps';

Set<String> _payloadsWithFmtp(List<String> lines) => {
      for (final line in lines)
        if (_fmtp.firstMatch(line) case final match?) match.group(1)!,
    };
