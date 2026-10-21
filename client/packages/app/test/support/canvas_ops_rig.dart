// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The commit queue and accepted-op reply every canvas ops controller test
/// builds its own rig from.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';

/// A [CanvasCommitQueue] whose callbacks are all no-ops.
CanvasCommitQueue plainCommitQueue(api.SlimmApi client) => CanvasCommitQueue(
  client: client,
  channelId: 'c1',
  onPlaced: (_) {},
  onFailed: (_, _) {},
  onRemoved: (_) {},
  onEraseOnConfirm: (_) async {},
  timedOutUntil: () => null,
);

/// The server's reply to an op it accepted as the [n]th request.
http.Response acceptedOp({
  required int n,
  required Object? kind,
  required int affected,
  int status = 200,
}) => http.Response(
  jsonEncode({
    'op': {
      'id': 'op-$n',
      'seq': n,
      'kind': kind,
      'affected': affected,
      'created_at': 0,
    },
    'fresh': true,
  }),
  status,
  headers: {'content-type': 'application/json'},
);
