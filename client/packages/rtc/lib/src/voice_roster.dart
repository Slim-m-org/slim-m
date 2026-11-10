// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who is in a voice call and what they are doing, as the session reports it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'speaking_hold.dart';
import 'voice_models.dart';
import 'voice_roster_snapshot.dart';

/// What [VoiceRoster] needs from the session that owns it.
class VoiceRosterHost {
  const VoiceRosterHost({
    required this.refresh,
    required this.reconnecting,
    required this.localVoice,
    required this.deafened,
  });

  /// Rebuilds the whole call state, which ends in [VoiceRoster.update].
  final void Function() refresh;

  /// Only a full restart empties the SDK's remote list.
  final bool Function() reconnecting;

  /// Your own voice state from the input gate, or null when the SFU's report is all there is.
  final bool? Function() localVoice;
  final bool Function() deafened;
}

/// Builds the roster from the live room and emits it only when it changed.
class VoiceRoster {
  VoiceRoster(this._host);

  final VoiceRosterHost _host;
  final _controller = StreamController<List<VoiceParticipant>>.broadcast();
  final _localLevels = StreamController<double>.broadcast();
  final SpeakingHold _hold = SpeakingHold();
  Timer? _holdTimer;
  List<VoiceParticipant> _participants = const [];
  double _sensitivity = 1.0;
  double _lastLocalLevel = 0;

  List<VoiceParticipant> get participants => _participants;
  Stream<List<VoiceParticipant>> get changes => _controller.stream;

  /// Your microphone's level as the SFU last reported it, for hosts with no input gate.
  /// Kept off the roster because a level change there rebuilds the whole call.
  Stream<double> get localLevels => _localLevels.stream;

  /// How readily [VoiceParticipant.isSpeaking] reports true; see
  /// [passesActivationThreshold] for what this can and cannot do.
  ///
  /// Safe before a room exists, and live mid-call: it re-evaluates the roster.
  void setSensitivity(double sensitivity) {
    _sensitivity = sensitivity.clamp(0.0, 1.0);
    _host.refresh();
  }

  /// Rebuilds from [room], keeping a speaking ring up briefly after the voice stops.
  void update(lk.Room room) {
    if (_host.reconnecting()) {
      _reportLocalLevel(const []);
      return;
    }
    final localVoice = _host.localVoice();
    final (next, recheck) = _hold.apply(
      snapshotParticipants(
        room,
        speakingSensitivity: _sensitivity,
        localVoice: localVoice,
        localDeafened: _host.deafened(),
      ),
      skipLocal: localVoice != null,
    );
    _holdTimer?.cancel();
    _holdTimer = recheck == null ? null : Timer(recheck, _host.refresh);
    // Only emit on a real change: the events stream is chatty, and rebuilding the roster every time is how that janks.
    if (listEquals(next, _participants)) {
      _reportLocalLevel(next);
      return;
    }
    set(List.unmodifiable(next));
  }

  /// The one place the roster changes, so your level is reported with it and never outlives the people it came from.
  void set(List<VoiceParticipant> next) {
    _participants = next;
    _reportLocalLevel(next);
    if (!_controller.isClosed) _controller.add(next);
  }

  /// Stops the pending speaking-hold recheck, for a call that is ending.
  void cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _reportLocalLevel(List<VoiceParticipant> roster) {
    final level = roster.where((p) => p.isLocal).firstOrNull?.audioLevel ?? 0;
    if (level == _lastLocalLevel) return;
    _lastLocalLevel = level;
    if (!_localLevels.isClosed) _localLevels.add(level);
  }

  Future<void> dispose() async {
    await _localLevels.close();
    await _controller.close();
  }
}
