// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Brings a call back after the network took it away, without anybody
/// having to notice and tap.
///
/// LiveKit retries a dropped connection itself, on its own schedule
/// (`defaultRetryDelaysInMs` in livekit_client 2.10.0: ten attempts spanning
/// 44 seconds). This picks up where that gives up. Until it existed, a
/// client whose transport outlasted that budget landed in
/// [VoiceSessionState.failed] and stayed there: `VoiceController`'s
/// heartbeat stopped, and the only way back into the call was the manual
/// "Try again" on `VoiceRejoinScreen`. That is a reasonable last resort and
/// a poor first one - a phone that changes network in a lift comes back on
/// its own, and the call should too.
///
/// Its own file, the shape `voice_call_heartbeat.dart` already set: a small
/// timer-owning collaborator, so `voice_controller.dart` gains the decision
/// and not the bookkeeping.
///
/// Deliberately bounded. Retrying forever would keep a screen claiming to
/// reconnect long after anybody watching it had given up, so the attempts
/// run out after a few minutes and the manual surface takes over. An
/// attempt made with no network fails at the token request without touching
/// the SFU, so the slow tail costs a request every half minute, not a
/// connection.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/sync_controller.dart';

class VoiceAutoRejoin {
  VoiceAutoRejoin({this.delays = defaultDelays});

  /// One entry per attempt, measured from the previous failure.
  ///
  /// The first three widen quickly for the common case where the network is
  /// already back by the time LiveKit stops trying, or a handover is still
  /// settling. The tail is patient: a tunnel or a lift keeps a phone offline
  /// well past LiveKit's 44 seconds, and a client that gives up after
  /// seventeen more strands somebody who came back a minute later. Measured
  /// against a real SFU, a client offline for 90 seconds exhausted the old
  /// three attempts while still offline and then sat on "Try again" with a
  /// working network.
  static const defaultDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
  ];

  /// How long a connection must hold before the budget is restored, so a
  /// flapping link spends one budget across its connects instead of a fresh one each.
  static const stableAfter = Duration(seconds: 60);

  final List<Duration> delays;

  Timer? _timer;
  int _spent = 0;
  DateTime? _connectedAt;

  /// Records a successful connect and drops any stale queued attempt.
  void connected() {
    cancelPending();
    _connectedAt = clock.now();
  }

  /// Whether an attempt is waiting to run, so a screen can say it is
  /// reconnecting rather than showing an error nothing asked the user to act
  /// on yet.
  bool get pending => _timer != null;

  /// Runs [attempt] after the next delay, and answers whether it scheduled
  /// anything: `false` means the attempts are spent and whoever called this
  /// owns what the user sees next.
  bool schedule(void Function() attempt) {
    final connectedAt = _connectedAt;
    _connectedAt = null;
    if (connectedAt != null &&
        clock.now().difference(connectedAt) >= stableAfter) {
      _spent = 0;
    }
    if (_spent >= delays.length) return false;
    _timer?.cancel();
    final delay = delays[_spent++];
    _timer = Timer(delay, () {
      _timer = null;
      attempt();
    });
    return true;
  }

  bool _watchingSync = false;

  /// Runs [attempt] the moment sync reports the socket live again, if one is
  /// waiting.
  ///
  /// Subscribed on the first call rather than at construction, so a client
  /// that never loses a call never builds the sync controller for this.
  void watchSync(Ref ref, void Function() attempt) {
    if (_watchingSync) return;
    _watchingSync = true;
    ref.listen<SyncStatus>(syncControllerProvider, (previous, next) {
      if (next != SyncStatus.live || previous == SyncStatus.live) return;
      runNow(attempt);
    });
  }

  /// Runs the waiting attempt now instead of when its timer fires, and
  /// answers whether there was one. Nothing pending means an attempt is
  /// already in flight or the budget is spent, so a caller cannot double a join.
  bool runNow(void Function() attempt) {
    if (_timer == null) return false;
    _timer!.cancel();
    _timer = null;
    attempt();
    return true;
  }

  /// Drops a queued attempt without spending or restoring anything, for a
  /// deliberate join that supersedes it. The budget survives on purpose: a
  /// person who taps into a different channel mid-reconnect has not told us
  /// anything about the drop this was recovering from.
  void cancelPending() {
    _timer?.cancel();
    _timer = null;
  }

  /// Drops any pending attempt and restores the full budget, for a call that
  /// ended or reconnected. Both halves matter: a connected call must not be
  /// interrupted by a stale timer, and the next drop is a new problem that
  /// deserves its own full budget rather than whatever this one left over.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _spent = 0;
    _connectedAt = null;
  }
}
