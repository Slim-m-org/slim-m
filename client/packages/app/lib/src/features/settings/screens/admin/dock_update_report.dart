// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How an Update all walk went, for the line under the Update all bar and the
/// error box.
library;

import 'package:slimm_api/api.dart' as api;

import '../../../../providers/admin_providers.dart';

/// An installed module that has an update, and the community source to install
/// it from (null for the official one).
typedef DockOutdated = ({api.DockIndexEntry entry, String? source});

/// A module that was updated and then left without access it had.
typedef DockLeftBare = ({api.DockIndexEntry entry, List<String> lost});

class DockUpdateReport {
  const DockUpdateReport({
    required this.total,
    required this.updated,
    required this.skipped,
    required this.failures,
    this.needPassword = const [],
    this.withoutAccess = const [],
  });

  final int total;
  final int updated;

  /// Modules the admin skipped, which keep their update.
  final List<api.DockIndexEntry> skipped;

  /// Administrator connectors left behind because the password prompt was dismissed.
  final List<api.DockIndexEntry> needPassword;

  /// One sentence per install that failed, with the reason.
  final List<String> failures;

  /// Modules updated whose withdrawn access the admin chose not to give back.
  final List<DockLeftBare> withoutAccess;

  /// The neutral line after a walk that left something undone, or null.
  ///
  /// Only modules still in that state are named: one updated or given its
  /// access from its own page since is not "skipped" or "without access".
  String? summary(DockCatalog catalog, List<DockOutdated> stillOutdated) {
    final behind = {for (final o in stillOutdated) o.entry.id};
    final skippedNow = [
      for (final entry in skipped)
        if (behind.contains(entry.id)) entry.name,
    ];
    final passwordNow = [
      for (final entry in needPassword)
        if (behind.contains(entry.id)) entry.name,
    ];
    final bareNow = [
      for (final (:entry, :lost) in withoutAccess)
        if (_stillLacks(catalog.installedFor(entry.id), lost)) entry.name,
    ];
    if (skippedNow.isEmpty &&
        passwordNow.isEmpty &&
        bareNow.isEmpty &&
        failures.isEmpty) {
      return null;
    }
    return [
      'Updated $updated of $total.',
      if (skippedNow.isNotEmpty) 'Skipped ${skippedNow.join(', ')}.',
      if (passwordNow.isNotEmpty) _needPasswordSentence(passwordNow),
      if (bareNow.isNotEmpty) _withoutAccessSentence(bareNow),
    ].join(' ');
  }
}

bool _stillLacks(api.InstalledDockModule? installed, List<String> lost) =>
    installed != null &&
    lost.any((c) => !installed.approvedHostCapabilities.contains(c));

String _needPasswordSentence(List<String> names) => names.length == 1
    ? '${names.single} needs your password to update.'
    : '${names.join(', ')} need your password to update.';

String _withoutAccessSentence(List<String> names) => names.length == 1
    ? '${names.single} was updated without the access it had.'
    : '${names.join(', ')} were updated without the access they had.';
