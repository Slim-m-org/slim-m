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
  const EdgeTrace({required this.colo, required this.country});

  /// The data centre code, such as `IAD`.
  final String colo;

  /// The two-letter country Cloudflare places this device in, when it says.
  final String? country;

  @override
  bool operator ==(Object other) =>
      other is EdgeTrace && other.colo == colo && other.country == country;

  @override
  int get hashCode => Object.hash(colo, country);
}

/// Reads only `colo=` and `loc=` from a trace body; the address it also carries is never kept.
EdgeTrace? parseCloudflareTrace(String body) {
  String? colo;
  String? country;
  for (final line in body.split('\n')) {
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    final value = line.substring(eq + 1).trim();
    switch (line.substring(0, eq)) {
      case 'colo':
        colo = _iata.hasMatch(value.toUpperCase()) ? value.toUpperCase() : null;
      case 'loc':
        country = RegExp(r'^[A-Za-z]{2}$').hasMatch(value)
            ? value.toUpperCase()
            : null;
    }
  }
  return colo == null ? null : EdgeTrace(colo: colo, country: country);
}

/// The API's route as its own traffic shows it: the last response's data
/// centre and the event socket's last round trip.
class EdgeWatch {
  EdgeWatch({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _changes = StreamController<void>.broadcast();

  /// The data centre the last response came through; null when it came
  /// straight from the server, or before any response.
  String? get colo => _colo;
  String? _colo;

  /// Whether any response has been seen, so a null [colo] means "no CDN".
  bool get seen => _seen;
  bool _seen = false;

  /// The event socket's last ping to pong.
  Duration? get roundTrip => _roundTrip;
  Duration? _roundTrip;

  /// When [roundTrip] was measured.
  DateTime? get measuredAt => _measuredAt;
  DateTime? _measuredAt;

  /// Fires on any change of the above.
  Stream<void> get changes => _changes.stream;

  void noteResponse(String? cfRay) {
    if (_changes.isClosed) return;
    final colo = cloudflareColoOf(cfRay);
    if (_seen && colo == _colo) return;
    _seen = true;
    _colo = colo;
    _changes.add(null);
  }

  void noteRoundTrip(Duration roundTrip) {
    if (_changes.isClosed) return;
    _roundTrip = roundTrip;
    _measuredAt = _clock();
    _changes.add(null);
  }

  void close() => unawaited(_changes.close());
}
