// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which Cloudflare data centre, if any, this device's requests pass through.
library;

import 'dart:async';

final _iata = RegExp(r'^[A-Z]{3}$');

/// The data centre code a `cf-ray` header ends in (`8f1c...-GRU`), or null.
String? cloudflareColoOf(String? cfRay) {
  if (cfRay == null) return null;
  final dash = cfRay.lastIndexOf('-');
  if (dash < 0) return null;
  final code = cfRay.substring(dash + 1).trim().toUpperCase();
  return _iata.hasMatch(code) ? code : null;
}

/// What Cloudflare's `/cdn-cgi/trace` says about a connection.
class EdgeTrace {
  const EdgeTrace({required this.colo});

  /// The data centre code, such as `IAD`.
  final String colo;

  @override
  bool operator ==(Object other) => other is EdgeTrace && other.colo == colo;

  @override
  int get hashCode => colo.hashCode;
}

/// Reads only `colo=` from a trace body; the address and location it also carries are never kept.
EdgeTrace? parseCloudflareTrace(String body) {
  for (final line in body.split('\n')) {
    if (!line.startsWith('colo=')) continue;
    final value = line.substring('colo='.length).trim().toUpperCase();
    return _iata.hasMatch(value) ? EdgeTrace(colo: value) : null;
  }
  return null;
}

/// One timed request to the server, with the way that same request travelled.
class EdgeReading {
  const EdgeReading({
    required this.colo,
    required this.direct,
    required this.roundTrip,
    required this.at,
  });

  /// The data centre the response came through; null when no Cloudflare was in between.
  final String? colo;

  /// Whether the request went over the server's own network.
  final bool direct;
  final Duration roundTrip;
  final DateTime at;
}

/// The API's route as its own timed requests last showed it.
class EdgeWatch {
  final _changes = StreamController<void>.broadcast();

  /// The last timed request; null before one answered.
  EdgeReading? get last => _last;
  EdgeReading? _last;

  /// Fires on each new [last].
  Stream<void> get changes => _changes.stream;

  void note(EdgeReading reading) {
    if (_changes.isClosed) return;
    _last = reading;
    _changes.add(null);
  }

  void close() => unawaited(_changes.close());
}
