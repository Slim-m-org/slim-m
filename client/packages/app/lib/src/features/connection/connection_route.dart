// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How this device reaches the Space right now, leg by leg, and when that route deserves a word.
///
/// Plain data and pure functions, so the thresholds are tested without a network.
library;

import 'package:slimm_api/api.dart' show EdgeReading, EdgeTrace;
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

/// How far a Cloudflare leg may run past the call audio's own round trip before it is a detour.
///
/// The normal path measured above sits at most about 110 ms past call audio.
const int kDetourMs = 200;

/// How long a leg's last measurement may stand behind a concern.
const Duration kConcernFreshFor = Duration(seconds: 60);

/// Which way the API's traffic reaches the server.
enum ServerRoute { localNetwork, cloudflare, internet }

/// The city a data centre code names, or the code itself when the table does not know it.
String coloCity(String colo) => cloudflareColos[colo]?.$1 ?? colo;

/// Everything the connection details show, as of [checkedAt].
class ConnectionReport {
  const ConnectionReport({
    this.server,
    this.serverColo,
    this.serverRttMs,
    this.serverAt,
    this.inCall = false,
    this.signalColo,
    this.signalRttMs,
    this.signalAt,
    this.signalSilent = false,
    this.signalDirect = false,
    this.media,
    this.mediaRttMs,
    this.checkedAt,
  });

  /// Null until the first timed request says which way it went.
  final ServerRoute? server;
  final String? serverColo;
  final int? serverRttMs;

  /// When the server leg was measured; a new value is a new measurement.
  final DateTime? serverAt;
  final bool inCall;
  final String? signalColo;
  final int? signalRttMs;

  /// When the signalling round trip was last renewed; a new value is a new measurement.
  final DateTime? signalAt;
  final bool signalSilent;

  /// The signalling socket goes over the server's own network, so no Cloudflare data centre is on its way.
  final bool signalDirect;
  final MediaRoute? media;
  final int? mediaRttMs;

  /// The older of the server leg's measurement and the call's last sample.
  final DateTime? checkedAt;
}

/// Builds the report from what each leg last measured; the server leg's route and figure come from one request.
ConnectionReport connectionReportOf({
  required EdgeReading? server,
  required EdgeTrace? signalTrace,
  required CallLink? call,
}) {
  final route = server == null
      ? null
      : server.colo != null
      ? ServerRoute.cloudflare
      : server.direct
      ? ServerRoute.localNetwork
      : ServerRoute.internet;
  final times = [server?.at, call?.at].whereType<DateTime>().toList()..sort();
  final signalDirect = call?.signalDirect ?? false;
  return ConnectionReport(
    server: route,
    serverColo: server?.colo,
    serverRttMs: server?.roundTrip.inMilliseconds,
    serverAt: server?.at,
    inCall: call != null,
    // The trace goes the public way, so it names a data centre the direct socket never passes.
    signalColo: call == null || signalDirect ? null : signalTrace?.colo,
    signalRttMs: call?.signalRttMs,
    signalAt: call?.signalAt,
    signalSilent: call?.signalSilent ?? false,
    signalDirect: signalDirect,
    media: call?.media,
    mediaRttMs: call?.mediaRttMs,
    checkedAt: times.firstOrNull,
  );
}

/// Why the route deserves a word: a Cloudflare leg measured slow beside quick call audio.
class RouteConcern {
  const RouteConcern({required this.city});

  /// The city of the data centre the slow leg passes through.
  final String city;

  String get message =>
      'Cloudflare is routing you through $city, and it is slow right now. '
      'Calls may be slower to join and to notice who left.';

  @override
  bool operator ==(Object other) => other is RouteConcern && other.city == city;

  @override
  int get hashCode => city.hashCode;
}

/// Whether [legMs] over Cloudflare is slow beside call audio at [mediaMs]; never without a call audio reading.
bool slowBesideMedia(int? legMs, int? mediaMs) {
  if (legMs == null || mediaMs == null) return false;
  return (legMs >= kSlowRouteMs && mediaMs < kQuickMediaMs) ||
      legMs - mediaMs >= kDetourMs;
}

/// The concern the server leg raises on its own, before any smoothing.
RouteConcern? serverConcernOf(ConnectionReport r) =>
    r.server == ServerRoute.cloudflare &&
        slowBesideMedia(r.serverRttMs, r.mediaRttMs)
    ? RouteConcern(city: coloCity(r.serverColo!))
    : null;

/// The concern the signalling leg raises on its own, before any smoothing.
RouteConcern? signalConcernOf(ConnectionReport r) =>
    r.signalColo != null && slowBesideMedia(r.signalRttMs, r.mediaRttMs)
    ? RouteConcern(city: coloCity(r.signalColo!))
    : null;

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

/// One leg's [RouteConcernGate], fed once per measurement, never per recompute, and only in a call.
class _LegWatch {
  _LegWatch(this._concernOf, this._measuredAt);

  final RouteConcern? Function(ConnectionReport) _concernOf;
  final DateTime? Function(ConnectionReport) _measuredAt;
  RouteConcernGate _gate = RouteConcernGate();
  DateTime? _seen;

  RouteConcern? update(ConnectionReport r, DateTime now) {
    final at = r.inCall ? _measuredAt(r) : null;
    if (at == null) {
      _gate = RouteConcernGate();
      _seen = null;
      return null;
    }
    if (at != _seen) {
      _seen = at;
      _gate.update(_concernOf(r));
    }
    return now.difference(at) < kConcernFreshFor ? _gate.shown : null;
  }
}

/// The smoothed concern across the Cloudflare legs; see [RouteConcernGate].
class RouteWatch {
  final _signal = _LegWatch(signalConcernOf, (r) => r.signalAt);
  final _server = _LegWatch(serverConcernOf, (r) => r.serverAt);

  RouteConcern? update(ConnectionReport r, DateTime now) {
    final signal = _signal.update(r, now);
    final server = _server.update(r, now);
    return signal ?? server;
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
          r.signalDirect
              ? 'Your local network'
              : r.signalColo == null
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
