// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [TaskbarAttention] that records its calls instead of reaching the runner.
library;

import 'package:slimm_platform/platform.dart';

class FakeTaskbarAttention implements TaskbarAttention {
  final calls = <String>[];

  @override
  Future<void> flash() async => calls.add('flash');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> setBadge(int count) async => calls.add('badge:$count');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
