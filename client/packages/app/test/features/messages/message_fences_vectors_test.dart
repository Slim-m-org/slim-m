// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fence rules are asserted against the vector list the server's own
/// extractor reads (`crates/slimm-server/tests/fixtures/code_fence_vectors.json`),
/// so the block a viewer sees and the block the server runs cannot drift.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_fences.dart';

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/schema/openapi.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('repo root not found');
    dir = parent;
  }
  return dir;
}

void main() {
  final file = File(
    '${_repoRoot().path}/crates/slimm-server/tests/fixtures/code_fence_vectors.json',
  );
  final vectors = (jsonDecode(file.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  for (final v in vectors) {
    test('fence vector: ${v['name']}', () {
      final got = [
        for (final b in splitMessageBlocks(v['content'] as String))
          if (b is CodeBlock) {'language': b.language, 'code': b.code},
      ];
      expect(got, v['blocks']);
    });
  }
}
