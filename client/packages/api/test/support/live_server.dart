// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the live-server tests find the server they run against.
///
/// They skip themselves in an everyday `dart test`, which has no server. The
/// e2e harness sets `SLIMM_TEST_SERVER_REQUIRED=1` so that a run which was
/// meant to reach a server and has none fails instead of passing empty.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The server named by `SLIMM_TEST_SERVER`, or null when the suite should skip.
///
/// Registers a failing test when `SLIMM_TEST_SERVER_REQUIRED=1` and no server
/// is named, so the caller's `if (base == null) return;` cannot hide it.
Uri? liveServer() {
  final env = Platform.environment;
  final url = env['SLIMM_TEST_SERVER'];
  if (url != null && url.isNotEmpty) return Uri.parse(url);
  if (env['SLIMM_TEST_SERVER_REQUIRED'] == '1') {
    test('a live server is configured', () {
      fail('SLIMM_TEST_SERVER_REQUIRED is set but SLIMM_TEST_SERVER is not');
    });
  }
  return null;
}

/// The invite code from `SLIMM_TEST_INVITE`, for a server that only admits
/// people who hold one; null for an open server.
String? liveInviteCode() {
  final code = Platform.environment['SLIMM_TEST_INVITE'];
  return code == null || code.isEmpty ? null : code;
}
