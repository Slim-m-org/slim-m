// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How this device reaches the Space right now, leg by leg, and when that route deserves a word.
///
/// Plain data and pure functions, so the thresholds are tested without a network.
library;

import 'package:slimm_api/api.dart' show EdgeTrace;
import 'package:slimm_rtc/rtc.dart' show CallLink, MediaRoute;

import 'cloudflare_colos.g.dart';

/// A round trip over Cloudflare at or past which the route reads as slow.
///
/// Measured 2026-11-18 from the owner's network in Maryland through EWR: about 15-55 ms
/// to the edge and 60-130 ms to the server behind it. A detour through GRU adds
/// roughly 240 ms on top, so 250 ms sits clear of the normal path and under the detour.
const int kSlowRouteMs = 250;

/// A call audio round trip under which a slow route is the route's fault, not the network's.
const int kQuickMediaMs = 100;

/// Silence on the call's signalling socket that already means a lost answer.
///
/// LiveKit pings every few seconds and gives up after 15 s; past this one answer is overdue.
const Duration kSignalSilentAfter = Duration(seconds: 12);

/// Which way the API's traffic reaches the server.
enum ServerRoute { localNetwork, cloudflare, internet }

/// The city a data centre code names, or the code itself when the table does not know it.
String coloCity(String colo) => cloudflareColos[colo]?.$1 ?? colo;

String? _coloCountry(String? colo) =>
    colo == null ? null : cloudflareColos[colo]?.$2;

/// Everything the connection details show, as of [checkedAt].
class ConnectionReport {
  const ConnectionReport({
    this.server,
    this.serverColo,
    this.serverRttMs,
    this.country,
    this.inCall = false,
    this.signalColo,
    this.signalRttMs,
    this.signalSilent = false,
    this.media,
    this.mediaRttMs,
    this.checkedAt,
  });

  /// Null until the first response says which way it came.
  final ServerRoute? server;
  final String? serverColo;
  final int? serverRttMs;

  /// The two-letter country Cloudflare places this device in.
  final String? country;
  final bool inCall;
  final String? signalColo;
  final int? signalRttMs;
  final bool signalSilent;
  final MediaRoute? media;
  final int? mediaRttMs;
  final DateTime? checkedAt;
}

/// Builds the report from what each leg last measured.
ConnectionReport connectionReportOf({
  required bool direct,
  required bool responded,
  required String? apiColo,
  required Duration? apiRoundTrip,
  required DateTime? apiMeasuredAt,
  required EdgeTrace? serverTrace,
  required EdgeTrace? signalTrace,
  required CallLink? call,
  required DateTime now,
}) {
  final server = direct
      ? ServerRoute.localNetwork
      : !responded
      ? null
      : apiColo != null
      ? ServerRoute.cloudflare
      : ServerRoute.internet;
  final silence = call?.signalSilence;
  return ConnectionReport(
    server: server,
    serverColo: server == ServerRoute.cloudflare ? apiColo : null,
    serverRttMs: apiRoundTrip?.inMilliseconds,
    country: serverTrace?.country ?? signalTrace?.country,
    inCall: call != null,
    signalColo: call == null ? null : signalTrace?.colo,
    signalRttMs: call?.signalRttMs,
    signalSilent: silence != null && silence >= kSignalSilentAfter,
    media: call?.media,
    mediaRttMs: call?.mediaRttMs,
    checkedAt: call != null ? now : apiMeasuredAt,
  );
}

/// Why the route deserves a word, or null when it does not.
class RouteConcern {
  const RouteConcern({this.farCity});

  /// The data centre city outside the device's country; null when the concern is only speed.
  final String? farCity;

  String get message => farCity != null
      ? 'Cloudflare is routing you through $farCity right now. '
            'Calls may be slower to join and to notice who left.'
      : 'The route to the server is slow right now. '
            'Calls may be slower to join and to notice who left.';

  @override
  bool operator ==(Object other) =>
      other is RouteConcern && other.farCity == farCity;

  @override
  int get hashCode => farCity.hashCode;
}

/// The concern [report] raises on its own, before any smoothing.
RouteConcern? routeConcernOf(ConnectionReport report) {
  final home = report.country;
  for (final colo in [report.serverColo, report.signalColo]) {
    final where = _coloCountry(colo);
    if (home != null && where != null && where != home) {
      return RouteConcern(farCity: coloCity(colo!));
    }
  }
  final media = report.mediaRttMs;
  final quickMedia = media == null || media < kQuickMediaMs;
  final overCloudflare = [
    if (report.server == ServerRoute.cloudflare) report.serverRttMs,
    if (report.signalColo != null) report.signalRttMs,
  ].whereType<int>();
  if (quickMedia && overCloudflare.any((ms) => ms >= kSlowRouteMs)) {
    return const RouteConcern();
  }
  return null;
}

/// Shows a concern after two readings in a row, and clears it after three clean ones,
/// so a single flip between nearby data centres never flickers it.
class RouteConcernGate {
  static const showAfter = 2;
  static const clearAfter = 3;

  RouteConcern? _shown;
  int _bad = 0;
  int _clean = 0;

  RouteConcern? get shown => _shown;

  RouteConcern? update(RouteConcern? now) {
    if (now == null) {
      _bad = 0;
      if (_shown != null && ++_clean >= clearAfter) _shown = null;
    } else {
      _clean = 0;
      if (_shown != null || ++_bad >= showAfter) _shown = now;
    }
    return _shown;
  }
}

/// One line of the details: what the leg is, how it travels, and whether that is worth a look.
typedef ConnectionLeg = ({String label, String value, bool warn});

// A no-break space, so a figure never wraps away from its unit.
String _withRtt(String route, int? ms) =>
    ms == null ? route : '$route, $ms\u00a0ms';

/// The three legs in the words both surfaces use.
List<ConnectionLeg> connectionLegs(ConnectionReport r) {
  final serverRoute = switch (r.server) {
    null => 'Checking',
    ServerRoute.localNetwork => 'Your local network',
    ServerRoute.cloudflare => 'Cloudflare ${coloCity(r.serverColo!)}',
    ServerRoute.internet => 'Internet',
  };
  final signal = !r.inCall
      ? 'Not in a call'
      : r.signalSilent
      ? 'Not answering'
      : _withRtt(
          r.signalColo == null
              ? 'Internet'
              : 'Cloudflare ${coloCity(r.signalColo!)}',
          r.signalRttMs,
        );
  final media = !r.inCall
      ? 'Not in a call'
      : _withRtt(switch (r.media) {
          null => 'Connecting',
          MediaRoute.direct => 'Direct',
          MediaRoute.directTcp => 'Direct (TCP fallback)',
          MediaRoute.relayed => 'Relayed through the server',
        }, r.mediaRttMs);
  return [
    (
      label: 'Server',
      value: _withRtt(serverRoute, r.serverRttMs),
      warn: (r.serverRttMs ?? 0) >= kSlowRouteMs,
    ),
    (
      label: 'Call signalling',
      value: signal,
      warn: r.signalSilent || (r.signalRttMs ?? 0) >= kSlowRouteMs,
    ),
    (label: 'Call audio', value: media, warn: false),
  ];
}

/// "Checked 12 s ago", or null before anything was measured.
String? checkedLine(DateTime? at, DateTime now) {
  if (at == null) return null;
  final seconds = now.difference(at).inSeconds;
  if (seconds < 2) return 'Checked just now';
  if (seconds < 60) return 'Checked $seconds s ago';
  return 'Checked ${seconds ~/ 60} min ago';
}
