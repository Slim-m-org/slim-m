// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A name quoted in inline code or a fenced block is not a mention. Asserted
/// against the vector list the server's mention scan reads
/// (`crates/slimm-server/tests/fixtures/code_fence_vectors.json`), so the
/// chime and the server's badge agree on where code starts and ends.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_mentions.dart';
import 'package:slimm_test_support/source_gates.dart';

void main() {
  final file = File(
    '${findRepoRoot().path}/crates/slimm-server/tests/fixtures/code_fence_vectors.json',
  );
  final vectors = (jsonDecode(file.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>()
      .where((v) => v.containsKey('mentions'))
      .toList();

  test('the shared vectors carry mention expectations', () {
    expect(vectors.length, greaterThanOrEqualTo(8));
  });

  for (final v in vectors) {
    test('mention vector: ${v['name']}', () {
      final content = v['content'] as String;
      for (final name in (v['mentions'] as List).cast<String>()) {
        expect(messageMentionsUsername(content, name), isTrue, reason: name);
      }
      for (final name in (v['quoted'] as List).cast<String>()) {
        expect(messageMentionsUsername(content, name), isFalse, reason: name);
      }
    });
  }
}
