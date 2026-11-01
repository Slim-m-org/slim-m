// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a viewer's own player on the room's position, and says when to give up.
///
/// Pure: the caller feeds it the room's target, the player's position and the
/// time, and applies what comes back. Decision 0050 section 6 sets the rule:
/// under 0.25s nothing, up to 2s a playback rate within 5%, past 2s or on any
/// epoch change a seek, and a viewer who cannot hold the line (three
/// corrections inside 60 seconds, or a stall over 10 seconds) drops back to
/// the shared track. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

const Duration kDriftIgnored = Duration(milliseconds: 250);
const Duration kDriftSeeks = Duration(seconds: 2);
const double kMaxRateShift = 0.05;
const int kCorrectionsBeforeGivingUp = 3;
const Duration kCorrectionWindow = Duration(seconds: 60);
const Duration kStallLimit = Duration(seconds: 10);

/// A rate correction ends once the error is this small, so it does not chatter at the 0.25s edge.
const Duration _kRateSettled = Duration(milliseconds: 50);

enum GiveUpReason { drifting, stalled }

/// What the caller applies to its player.
sealed class Correction {
  const Correction();
}

class NoCorrection extends Correction {
  const NoCorrection();
}

class SetRate extends Correction {
  const SetRate(this.rate);
  final double rate;
}

class SeekTo extends Correction {
  const SeekTo(this.position);
  final Duration position;
}

class GiveUp extends Correction {
  const GiveUp(this.reason);
  final GiveUpReason reason;
}

class DirectPlayCorrector {
  int? _epoch;
  bool _rateActive = false;
  final List<DateTime> _corrections = [];
  DateTime? _stalledSince;

  /// One look at the player.
  ///
  /// [target] is where the room is now and [actual] where the player is;
  /// [roomPlaying] is false while the room is paused, and [stuck] is true while
  /// the player is buffering or its position is not moving though it should.
  Correction step({
    required Duration target,
    required Duration actual,
    required int epoch,
    required bool roomPlaying,
    required bool stuck,
    required DateTime now,
  }) {
    final epochChanged = _epoch != null && _epoch != epoch;
    _epoch = epoch;
    final stall = _stall(stuck && roomPlaying, now);
    if (stall != null) return stall;
    // A player that is not moving cannot be steered, and its drift is the stall's to report.
    if (stuck && roomPlaying) return const NoCorrection();
    final error = target - actual;
    if (epochChanged || error.abs() > kDriftSeeks) {
      _rateActive = false;
      // A seek the room asked for is not the player failing to keep up.
      if (!epochChanged && roomPlaying) {
        final gave = _record(now);
        if (gave != null) return gave;
      }
      return SeekTo(target);
    }
    return roomPlaying ? _rate(error, now) : _held(error, target);
  }

  /// A paused room is held by seeking, never by speeding up toward a frozen target.
  Correction _held(Duration error, Duration target) {
    if (_rateActive) {
      _rateActive = false;
      return const SetRate(1.0);
    }
    return error.abs() > kDriftIgnored ? SeekTo(target) : const NoCorrection();
  }

  Correction _rate(Duration error, DateTime now) {
    final size = error.abs();
    if (_rateActive && size <= _kRateSettled) {
      _rateActive = false;
      return const SetRate(1.0);
    }
    if (_rateActive || size < kDriftIgnored) return const NoCorrection();
    final gave = _record(now);
    if (gave != null) return gave;
    _rateActive = true;
    return SetRate(error.isNegative ? 1 - kMaxRateShift : 1 + kMaxRateShift);
  }

  GiveUp? _record(DateTime now) {
    _corrections
      ..removeWhere((at) => now.difference(at) > kCorrectionWindow)
      ..add(now);
    return _corrections.length >= kCorrectionsBeforeGivingUp
        ? const GiveUp(GiveUpReason.drifting)
        : null;
  }

  GiveUp? _stall(bool stuck, DateTime now) {
    if (!stuck) {
      _stalledSince = null;
      return null;
    }
    final since = _stalledSince ??= now;
    return now.difference(since) > kStallLimit
        ? const GiveUp(GiveUpReason.stalled)
        : null;
  }
}
