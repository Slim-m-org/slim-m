// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fence rules are asserted against the vector list the server's own
/// extractor reads (`crates/slimm-server/tests/fixtures/code_fence_vectors.json`),
/// so the block a viewer sees and the block the server runs cannot drift.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_fences.dart';
import 'package:slimm_test_support/source_gates.dart';

void main() {
  final file = File(
    '${findRepoRoot().path}/crates/slimm-server/tests/fixtures/code_fence_vectors.json',
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
