// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// The Dock: the module marketplace's browse, install and lifecycle calls.
/// Every route here requires MANAGE_SERVER. See
/// `docs/decisions/0021-modules-and-the-dock.md` - this is Phase 1 (browse)
/// and Phase 2 (install/enable/uninstall, dynamic permissions) only; no
/// module code ever runs from anything in this file.
extension SlimmApiDock on SlimmApi {
  /// Browses a source's index; [source] is a [DockSource.id], and null is the
  /// official one. Nothing is installed by this call.
  Future<List<DockIndexEntry>> listDockModules({String? source}) async {
    final json = await _send(
      'GET',
      '/space/dock/modules',
      query: _sourceQuery(source),
    );
    return (json as List<dynamic>)
        .map((m) => DockIndexEntry.fromJson(m as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Reads one module's full manifest, including every permission it will
  /// register and every capability it asks for, before installing it.
  Future<DockManifest> getDockModule(String moduleId, {String? source}) async {
    final json = await _send(
      'GET',
      '/space/dock/modules/$moduleId',
      query: _sourceQuery(source),
    );
    return DockManifest.fromJson(json as Map<String, dynamic>);
  }

  /// Installs a module at [version], the one reviewed in the Dock. Refused
  /// with 409 if the registry's current manifest no longer matches it.
  /// Installed off (disabled); a separate [enableDockModule] call turns it
  /// on.
  ///
  /// [approvedHostCapabilities] is what the admin approved for `slim.host_call`
  /// after seeing it listed; an empty list withdraws every approval, and null
  /// keeps what was approved before (never adding to it). [approveLocalNetwork]
  /// is the separate yes to reach home-network addresses, only valid with
  /// `net.fetch` approved. [reviewedDigest] is the manifest's `reviewDigest`
  /// the admin was shown; the server refuses the install if it has changed.
  Future<InstalledDockModule> installDockModule({
    required String moduleId,
    required String version,
    List<String>? approvedHostCapabilities,
    bool? approveLocalNetwork,
    String? reviewedDigest,
    String? source,
  }) async {
    final json = await _send(
      'POST',
      '/space/dock/modules/$moduleId/install',
      query: _sourceQuery(source),
      body: {
        'version': version,
        if (approvedHostCapabilities != null)
          'approved_host_capabilities': approvedHostCapabilities,
        if (approveLocalNetwork != null)
          'approve_local_network': approveLocalNetwork,
        if (reviewedDigest != null) 'reviewed_digest': reviewedDigest,
      },
    );
    return InstalledDockModule.fromJson(json as Map<String, dynamic>);
  }

  /// Chooses the text channel a module's scheduled runs post in; null stops
  /// them. Refused with 409 while `schedule` is not approved.
  Future<InstalledDockModule> setDockModuleScheduleChannel(
    String moduleId,
    String? channelId,
  ) async {
    final json = await _send(
      'PUT',
      '/space/dock/modules/$moduleId/schedule-channel',
      body: {'channel_id': channelId},
    );
    return InstalledDockModule.fromJson(json as Map<String, dynamic>);
  }

  /// Uninstalls a module: removes the install, its registered permissions,
  /// and every role grant of them.
  Future<void> uninstallDockModule(String moduleId) => _send(
        'DELETE',
        '/space/dock/modules/$moduleId/install',
        expectNoContent: true,
      );

  /// Empties what an installed module has stored; it stays installed.
  Future<void> clearDockModuleStorage(String moduleId) => _send(
        'DELETE',
        '/space/dock/modules/$moduleId/storage',
        expectNoContent: true,
      );

  /// Enables an installed module.
  Future<InstalledDockModule> enableDockModule(String moduleId) async {
    final json = await _send('POST', '/space/dock/modules/$moduleId/enable');
    return InstalledDockModule.fromJson(json as Map<String, dynamic>);
  }

  /// Disables an installed module without losing its config.
  Future<InstalledDockModule> disableDockModule(String moduleId) async {
    final json = await _send('POST', '/space/dock/modules/$moduleId/disable');
    return InstalledDockModule.fromJson(json as Map<String, dynamic>);
  }

  Map<String, String>? _sourceQuery(String? source) =>
      source == null ? null : {'source': source};

  /// The module sources, the official one first.
  Future<List<DockSource>> listDockSources() async {
    final json = await _send('GET', '/space/dock/sources');
    return (json as List<dynamic>)
        .map((s) => DockSource.fromJson(s as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Adds a community source by its GitHub `owner/repo`; a URL is refused.
  Future<DockSource> addDockSource(String repo) async {
    final json = await _send(
      'POST',
      '/space/dock/sources',
      body: {'repo': repo},
    );
    return DockSource.fromJson(json as Map<String, dynamic>);
  }

  /// Removes a community source. Modules installed from it stay installed.
  Future<void> removeDockSource(String sourceId) => _send(
        'DELETE',
        '/space/dock/sources/${Uri.encodeComponent(sourceId)}',
        expectNoContent: true,
      );

  /// Every module this space currently has installed.
  Future<List<InstalledDockModule>> listInstalledDockModules() async {
    final json = await _send('GET', '/space/dock/installed');
    return (json as List<dynamic>)
        .map((m) => InstalledDockModule.fromJson(m as Map<String, dynamic>))
        .toList(growable: false);
  }
}
