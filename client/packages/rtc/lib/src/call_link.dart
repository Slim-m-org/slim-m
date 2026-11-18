// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How this device reaches the call right now: the media path and the
/// signalling socket, measured apart because they take different routes.
library;

// ignore_for_file: invalid_use_of_internal_member

import 'package:livekit_client/livekit_client.dart' as lk;

import 'call_stats.dart';

/// Which way the call's audio travels.
enum MediaRoute {
  /// Straight to the voice server over UDP.
  direct,

  /// Straight to the voice server, over the TCP fallback.
  directTcp,

  /// Through the server's relay (TURN).
  relayed,
}

/// The route [transport] describes, or null before a candidate pair is known.
MediaRoute? mediaRouteOf(TransportStats? transport) {
  if (transport == null) return null;
  if (transport.localType == null && transport.remoteType == null) return null;
  if (transport.relayed) return MediaRoute.relayed;
  return transport.protocol == 'tcp' ? MediaRoute.directTcp : MediaRoute.direct;
}

/// Silence on the call's signalling socket that already means a lost answer.
///
/// LiveKit pings every few seconds and gives up after 15 s; past this one answer is overdue.
const Duration kSignalSilentAfter = Duration(seconds: 12);

/// One reading of the call's two legs; any part is null until measured.
class CallLink {
  const CallLink({
    this.mediaRttMs,
    this.media,
    this.signalRttMs,
    this.signalSilence,
    this.signalAt,
    this.at,
  });

  /// Round trip of the media path, in whole milliseconds.
  final int? mediaRttMs;
  final MediaRoute? media;

  /// Round trip of the signalling socket, in whole milliseconds.
  final int? signalRttMs;

  /// How long the signalling socket has gone without answering a ping.
  final Duration? signalSilence;

  /// When [signalRttMs] was last renewed by an answer, so one answer counts once.
  final DateTime? signalAt;

  /// When this reading was taken.
  final DateTime? at;

  /// Whether the signalling socket has missed an answer, so who is in the call may be out of date.
  bool get signalSilent =>
      (signalSilence ?? Duration.zero) >= kSignalSilentAfter;

  CallLink copyWith({int? mediaRttMs, MediaRoute? media}) => CallLink(
        mediaRttMs: mediaRttMs ?? this.mediaRttMs,
        media: media ?? this.media,
        signalRttMs: signalRttMs,
        signalSilence: signalSilence,
        signalAt: signalAt,
        at: at,
      );

  @override
  bool operator ==(Object other) =>
      other is CallLink &&
      other.mediaRttMs == mediaRttMs &&
      other.media == media &&
      other.signalRttMs == signalRttMs &&
      other.signalSilence == signalSilence &&
      other.signalAt == signalAt &&
      other.at == at;

  @override
  int get hashCode =>
      Object.hash(mediaRttMs, media, signalRttMs, signalSilence, signalAt, at);
}

/// Times the signalling socket's answers from the SDK's own ping counter.
class SignalPulse {
  SignalPulse({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  int? _pings;
  DateTime? _heardAt;

  /// Feeds the SDK's pong count and round trip; a count of 0 is not yet measured.
  ({int? rttMs, Duration? silence, DateTime? heardAt}) observe({
    required int pings,
    required int rttMs,
  }) {
    final now = _clock();
    if (pings != _pings) {
      _pings = pings;
      _heardAt = now;
    }
    if (pings == 0) return (rttMs: null, silence: null, heardAt: null);
    final heard = _heardAt;
    return (
      rttMs: rttMs > 0 ? rttMs : null,
      silence: heard == null ? null : now.difference(heard),
      heardAt: heard,
    );
  }

  void reset() {
    _pings = null;
    _heardAt = null;
  }
}

/// The SDK's signalling ping count and round trip for [room].
({int pings, int rttMs}) signalCounters(lk.Room room) {
  final signal = room.engine.signalClient;
  return (pings: signal.pingCount, rttMs: signal.rtt);
}
