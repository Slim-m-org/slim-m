// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fake server behind the conversation-and-search review suites: the shared
/// fixture's answers with a member's permissions, overwrites, a request that
/// never answers, and reduced motion layered on top.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart'
    show jsonHttpResponse;

import '../ui_snapshot_support.dart';

/// A case's own answer to a request, or null to fall through to the shared fixture.
typedef ReviewServe = FutureOr<http.Response?> Function(http.Request request);

/// A 200 answer carrying [body] as JSON.
http.Response jsonOk(Object body) => jsonHttpResponse(body);

class _ReducedMotion extends MotionPreferenceController {
  _ReducedMotion(super.ref) {
    state = MotionOverride.alwaysReduce;
  }
}

/// A spinner under reduced motion is a fixed arc, so a loading frame reads the same in both themes.
Override reducedMotion() =>
    motionPreferenceControllerProvider.overrideWith(_ReducedMotion.new);

final _hung = <Completer<http.Response?>>[];

/// A request that stays in flight for the whole capture and is let go at teardown, so no 45 s timeout is left pending.
Future<http.Response?> hangUntilTeardown() {
  final request = Completer<http.Response?>();
  _hung.add(request);
  return request.future;
}

void releaseHungRequests() {
  for (final request in _hung) {
    if (!request.isCompleted) request.complete(null);
  }
  _hung.clear();
}

/// One role allowed to send and one denied attachments: a grid with something in it.
const _overwrites = [
  {'kind': 'role', 'id': 'role-everyone', 'allow': 0, 'deny': 1024},
  {'kind': 'role', 'id': 'role-longname', 'allow': 4, 'deny': 0},
];

/// The shared fixture's server with the answers a conversation review needs on top.
///
/// The fixture answers every channel's permissions with an empty list, which the client reads as none at all.
http.Client reviewClient({
  ReviewServe? serve,
  int permissions = -1,
  int? timedOutUntil,
  String? timeoutReason,
}) => MockClient((request) async {
  final custom = await serve?.call(request);
  if (custom != null) return custom;
  final path = request.url.path;
  if (path == '/me') {
    return jsonOk({
      'id': 'user-nick',
      'username': 'nick',
      'display_name': 'Nick',
      'created_at': 0,
      'permissions': permissions,
      'timed_out_until': timedOutUntil,
      'timeout_reason': timeoutReason,
    });
  }
  if (path.startsWith('/channels/') && path.endsWith('/permissions')) {
    return jsonOk({'permissions': permissions});
  }
  if (path.startsWith('/channels/') && path.endsWith('/overwrites')) {
    return jsonOk({'overwrites': _overwrites});
  }
  return fixtureResponse(request);
});

Override reviewApi(http.Client client) => apiProvider.overrideWith((ref) {
  final slimm = api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: ref.watch(sessionProvider),
    httpClient: client,
  );
  ref.onDispose(slimm.close);
  return slimm;
});
