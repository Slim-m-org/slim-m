// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'cross_tab.dart';

CrossTab createCrossTab() => _SingleProcess();

class _SingleProcess implements CrossTab {
  @override
  Future<T> exclusive<T>(String name, Future<T> Function() body) => body();

  @override
  Stream<void> get storageChanges => const Stream.empty();
}
