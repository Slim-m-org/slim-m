// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mutable transport state one [SlimmApi] shares with its endpoint libraries.
library;

import 'package:http/http.dart' as http;

import 'direct_route.dart';
import 'models.dart';

class ApiLink {
  ApiLink({required this.client, required this.route});

  final http.Client client;

  /// The shortcut over the server's own network, when the client owns its
  /// transport; null when a caller handed in an [http.Client].
  final DirectRoute? route;

  /// Upload sessions a caller gave up on while they were still resumable,
  /// keyed by the caller's own resume key, so a retry carries on from there.
  final Map<String, String> resumableUploads = {};

  Future<TokenPair>? refreshInFlight;
}
