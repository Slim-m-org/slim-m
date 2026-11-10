// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// permessage-deflate interop between the Dart client and the Rust server.
///
/// Compression is negotiated per connection, and a mismatch does not fail
/// loudly: it produces frames one side cannot read, which surfaces much later
/// as "messages sometimes do not arrive". Checking it explicitly, early, is
/// cheap compared to finding it in the field.
///
/// Runs against a real server when SLIMM_TEST_SERVER is set, and is a no-op
/// otherwise; the e2e harness sets SLIMM_TEST_SERVER_REQUIRED so a missing
/// server fails there (`scripts/lib/e2e_client_contract.py`).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  final base = liveServer();
  if (base == null) return;

  test('the server negotiates or declines compression consistently', () async {
    final wsUrl = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws',
    );

    // Either answer to the offer is fine; what matters is that the connection
    // works, rather than the ends disagreeing about whether frames deflate.
    final socket = await WebSocket.connect(
      wsUrl.toString(),
      compression: CompressionOptions.compressionDefault,
    );
    addTearDown(socket.close);

    final frames = <String>[];
    final done = socket
        .map((raw) => raw is String ? raw : utf8.decode(raw as List<int>))
        .listen(frames.add)
        .asFuture<void>()
        .timeout(const Duration(seconds: 3), onTimeout: () {});

    // An invalid ticket still produces a well-formed error frame, which is all
    // this needs: a frame that decodes proves the framing agreed.
    socket.add(jsonEncode({
      'type': 'hello',
      'ticket': 'interop-probe',
      'protocol': protocolVersion,
    }));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await socket.close();
    await done;

    expect(
      frames,
      isNotEmpty,
      reason: 'a compressed connection produced no readable frame, which means '
          'the two ends disagree about permessage-deflate',
    );
    final decoded = jsonDecode(frames.first) as Map<String, dynamic>;
    expect(decoded['type'], isNotNull);
  });

  test('an uncompressed connection still works', () async {
    final wsUrl = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws',
    );
    final socket = await WebSocket.connect(
      wsUrl.toString(),
      compression: CompressionOptions.compressionOff,
    );
    addTearDown(socket.close);

    final frames = <String>[];
    socket
        .map((raw) => raw is String ? raw : utf8.decode(raw as List<int>))
        .listen(frames.add);

    socket.add(jsonEncode({
      'type': 'hello',
      'ticket': 'interop-probe',
      'protocol': protocolVersion,
    }));
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(frames, isNotEmpty,
        reason: 'the server must serve clients that '
            'decline compression, not only those that offer it');
  });
}
