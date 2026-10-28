// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which of libwebrtc's own microphone filters are on, for the desktop capture.
library;

import 'package:flutter/foundation.dart' show immutable;

@immutable
class VoiceProcessing {
  const VoiceProcessing({
    this.echoCancellation = true,
    this.autoGainControl = true,
    this.noiseSuppression = true,
  });

  final bool echoCancellation;
  final bool autoGainControl;
  final bool noiseSuppression;

  VoiceProcessing copyWith({
    bool? echoCancellation,
    bool? autoGainControl,
    bool? noiseSuppression,
  }) =>
      VoiceProcessing(
        echoCancellation: echoCancellation ?? this.echoCancellation,
        autoGainControl: autoGainControl ?? this.autoGainControl,
        noiseSuppression: noiseSuppression ?? this.noiseSuppression,
      );

  /// For the `voice-ns:` log lines.
  String get summary => 'webrtc_ns=${_on(noiseSuppression)} '
      'aec=${_on(echoCancellation)} agc=${_on(autoGainControl)}';

  static String _on(bool value) => value ? 'on' : 'off';

  @override
  bool operator ==(Object other) =>
      other is VoiceProcessing &&
      other.echoCancellation == echoCancellation &&
      other.autoGainControl == autoGainControl &&
      other.noiseSuppression == noiseSuppression;

  @override
  int get hashCode =>
      Object.hash(echoCancellation, autoGainControl, noiseSuppression);
}
