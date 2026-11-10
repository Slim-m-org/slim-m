// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line under the Update all bar names only what is still true: a module
/// given its access back from its own page is no longer "without" it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_update_report.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';

api.InstalledDockModule _installed(String id, List<String> approved) =>
    api.InstalledDockModule.fromJson({
      'id': id,
      'name': 'Mod $id',
      'version': '2.0.0',
      'artifact_sha256': 'a' * 64,
      'approved_capabilities': approved,
      'approved_host_capabilities': approved,
      'extension_points': <Map<String, dynamic>>[],
      'enabled': true,
      'installed_at': 1000,
    });

DockCatalog _catalog(List<api.InstalledDockModule> installed) =>
    DockCatalog(entries: const [], installed: installed);

api.DockIndexEntry _entry(String id) =>
    api.DockIndexEntry(id: id, name: 'Mod $id', version: '2.0.0', summary: '');

DockUpdateReport _report(List<DockLeftBare> bare) => DockUpdateReport(
  total: bare.length,
  updated: bare.length,
  skipped: const [],
  failures: const [],
  withoutAccess: bare,
);

void main() {
  test('names a module that is still without the access it had', () {
    final report = _report([
      (entry: _entry('a'), lost: ['kv.store']),
    ]);

    final line = report.summary(_catalog([_installed('a', [])]), const []);

    expect(
      line,
      'Updated 1 of 1. Mod a was updated without the access it had.',
    );
  });

  test('drops a module that was given the access back since', () {
    final report = _report([
      (entry: _entry('a'), lost: ['kv.store']),
    ]);

    final line = report.summary(
      _catalog([
        _installed('a', ['kv.store']),
      ]),
      const [],
    );

    expect(line, isNull);
  });

  test('drops a module that was uninstalled since', () {
    final report = _report([
      (entry: _entry('a'), lost: ['kv.store']),
    ]);

    expect(report.summary(_catalog(const []), const []), isNull);
  });

  test('names several modules in the plural', () {
    final report = _report([
      (entry: _entry('a'), lost: ['kv.store']),
      (entry: _entry('b'), lost: ['log.read']),
    ]);

    final line = report.summary(
      _catalog([_installed('a', []), _installed('b', [])]),
      const [],
    );

    expect(
      line,
      'Updated 2 of 2. Mod a, Mod b were updated without the access they had.',
    );
  });
}
