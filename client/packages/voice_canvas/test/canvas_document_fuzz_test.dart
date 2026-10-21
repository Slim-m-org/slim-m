// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Seeded random op streams against [CanvasDocument], checked after every step against an independent reference model (`support/canvas_document_model.dart`).
/// Violations are collected by category with the seed, step and op trace tail, and the test fails once at the end; `CANVAS_DOC_FUZZ_SEEDS`, `_STEPS` and `_POOL` size the run.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/canvas_document_fuzz_run.dart';

int _env(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

void main() {
  test(
    'random op streams keep the document consistent with the model '
    '(seeds x steps)',
    timeout: const Timeout(Duration(minutes: 5)),
    () {
      final violations = <String, DocumentFuzzViolation>{};
      for (var seed = 0; seed < _env('CANVAS_DOC_FUZZ_SEEDS', 300); seed++) {
        DocumentFuzzRun(
          seed,
          violations,
          steps: _env('CANVAS_DOC_FUZZ_STEPS', 160),
          idPool: _env('CANVAS_DOC_FUZZ_POOL', 12),
        ).run();
      }
      if (violations.isEmpty) return;
      final report = StringBuffer(
        '${violations.length} distinct violation(s):\n',
      );
      for (final entry in violations.entries) {
        final v = entry.value;
        report
          ..writeln('\n[${entry.key}] seed=${v.seed} step=${v.step}')
          ..writeln('  ${v.detail}')
          ..writeln('  trace tail:');
        for (final line in v.trace) {
          report.writeln('    $line');
        }
      }
      fail(report.toString());
    },
  );
}
