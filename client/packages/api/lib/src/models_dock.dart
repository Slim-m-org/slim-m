// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock: browsing, installing, and enabling modules from the addons
/// marketplace. See `docs/decisions/0021-modules-and-the-dock.md` for the
/// module system this is the client half of - slim ships the host and the
/// marketplace, never a module's own behavior.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

import 'models_dock_changelog.dart';
import 'models_dock_connector.dart';
import 'models_dock_host_run.dart';
import 'models_dock_runtime.dart';
import 'models_dock_platform.dart';

/// The `source` that reads a module installed from a package file back from the
/// server, and the repo such a module is recorded under.
const kFileDockSource = 'file';
const kFileDockRepo = 'local/file';

/// One row of the marketplace's index: enough to list a module, not enough
/// to install it. `GET /space/dock/modules`.
class DockIndexEntry {
  const DockIndexEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.summary,
    this.shadowed = false,
  });

  /// The module's slug id, stable across versions and safe for a URL path
  /// segment.
  final String id;
  final String name;
  final String version;
  final String summary;

  /// True when another source already owns [id], so it cannot be installed
  /// from the source this entry was listed under.
  final bool shadowed;

  factory DockIndexEntry.fromJson(Map<String, dynamic> json) => DockIndexEntry(
        id: json['id'] as String,
        name: json['name'] as String,
        version: json['version'] as String,
        summary: json['summary'] as String,
        shadowed: json['shadowed'] as bool? ?? false,
      );
}

/// A place the Dock reads modules from: the official registry, or a community
/// GitHub repo an admin added.
class DockSource {
  const DockSource({
    required this.id,
    required this.repo,
    required this.official,
    this.local = false,
  });

  /// Passed as `source` to the module routes; `official` for the official one.
  final String id;

  /// The GitHub `owner/repo` slug.
  final String repo;
  final bool official;

  /// The operator's own module directory (`dev`), never verified.
  final bool local;

  factory DockSource.fromJson(Map<String, dynamic> json) => DockSource(
        id: json['id'] as String,
        repo: json['repo'] as String,
        official: json['official'] as bool,
        local: json['local'] as bool? ?? false,
      );
}

/// One permission a module will register into the space's role editor on
/// install, namespaced by the module's own id once installed
/// (`code-exec:run`).
class DockPermission {
  const DockPermission({
    required this.key,
    required this.name,
    required this.description,
  });

  final String key;
  final String name;
  final String description;

  factory DockPermission.fromJson(Map<String, dynamic> json) => DockPermission(
        key: json['key'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
      );
}

/// One seam a module attaches to - a command, a message action, a scheduled
/// job, or a code-block runner.
class DockExtensionPoint {
  const DockExtensionPoint({
    required this.kind,
    required this.name,
    this.description,
    this.permission,
    this.command,
    this.language,
  });

  final String kind;
  final String name;
  final String? description;

  /// The declared permission key a caller must hold to reach this extension
  /// point. Always present for a `command` or a `code-block-runner`.
  final String? permission;

  /// For a `code-block-runner` only: the `command` extension point's own
  /// name it invokes.
  final String? command;

  /// For a `code-block-runner` only: the fenced-block language it matches,
  /// or null for a wildcard that matches any block.
  final String? language;

  factory DockExtensionPoint.fromJson(Map<String, dynamic> json) =>
      DockExtensionPoint(
        kind: json['kind'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        permission: json['permission'] as String?,
        command: json['command'] as String?,
        language: json['language'] as String?,
      );
}

/// Where a module's `net.fetch` may reach: the hosts it names, and whether it
/// also asks for local network addresses.
class DockNetwork {
  const DockNetwork({required this.hosts, required this.local});

  /// Lowercase `name` or `name:port` entries, as the admin sees them.
  final List<String> hosts;

  /// Needs the separate `approve_local_network` approval.
  final bool local;

  factory DockNetwork.fromJson(Map<String, dynamic> json) => DockNetwork(
        hosts: (json['hosts'] as List<dynamic>)
            .map((h) => h as String)
            .toList(growable: false),
        local: json['local'] as bool,
      );
}

/// A command the host runs on a timer once `schedule` is approved.
class DockSchedule {
  const DockSchedule({required this.command, required this.everyMinutes});

  final String command;
  final int everyMinutes;

  factory DockSchedule.fromJson(Map<String, dynamic> json) => DockSchedule(
        command: json['command'] as String,
        everyMinutes: json['every_minutes'] as int,
      );
}

List<DockSchedule> dockSchedules(Object? json) =>
    ((json as List<dynamic>?) ?? const [])
        .map((s) => DockSchedule.fromJson(s as Map<String, dynamic>))
        .toList(growable: false);

/// A module's full manifest, as `GET /space/dock/modules/{id}` returns it: the
/// permissions it will add and the capabilities it asks for, shown before an
/// admin ever installs it.
/// A module's own words about the calls it hears (decision 0105), shown word
/// for word at install and to everyone in a call before they agree.
class DockCallAudio {
  const DockCallAudio({
    required this.purpose,
    required this.keeps,
    this.permission,
  });

  final String purpose;
  final String keeps;

  /// A permission key of the module a member needs to start a session.
  final String? permission;

  factory DockCallAudio.fromJson(Map<String, dynamic> json) => DockCallAudio(
        purpose: json['purpose'] as String,
        keeps: json['keeps'] as String,
        permission: json['permission'] as String?,
      );
}

class DockManifest {
  const DockManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.summary,
    this.author,
    required this.artifact,
    required this.runtime,
    required this.permissions,
    required this.capabilities,
    required this.extensionPoints,
    this.network,
    this.schedules = const [],
    this.changelog = const [],
    this.subscriptions = const [],
    this.dataMaxMb,
    this.dataSchema,
    this.interceptors = const [],
    this.permissionHooks = const [],
    this.reviewDigest,
    this.callAudio,
    this.connectorPermissions,
    this.hostRun,
  });

  /// For a connector the host runs, the image, egress and limits it asks for (decision 0134).
  final HostRunAsk? hostRun;

  /// For a connector, the core permission bits its token asks for; null for a WASM module.
  final int? connectorPermissions;
  bool get isConnector => connectorPermissions != null;

  /// What it does with a call it hears, in its own words; absent without `call.audio`.
  final DockCallAudio? callAudio;

  /// Where it asks to stand in front of a message, and the permission checks it can deny.
  final List<DockHookDecl> interceptors;
  final List<DockHookDecl> permissionHooks;

  /// The tables and cap of its data store; null when it declares none.
  final DockDataSchema? dataSchema;

  /// Event kinds it subscribes to and its data store cap in MB.
  final List<String> subscriptions;
  final int? dataMaxMb;

  /// Sent back with the install so consent is for exactly this manifest.
  final String? reviewDigest;
  final String id;
  final String name;
  final String version;
  final String summary;
  final String? author;

  /// Release notes, newest first; empty when the module publishes none.
  final List<DockChangelogEntry> changelog;

  /// What to tell someone about this module: the newest entry when nothing is
  /// installed, otherwise every entry newer than [installedVersion].
  ///
  /// Numeric versions are sorted newest first whatever order they were
  /// published in; non-numeric ones follow in published order. When a
  /// comparison is impossible the entries listed before the installed one are
  /// the newer ones, and an installed version nobody lists yields only the
  /// newest entry rather than the whole history.
  List<DockChangelogEntry> changesSince(String? installedVersion) {
    final sorted = newestDockChangelogFirst(changelog);
    if (installedVersion == null) return sorted.take(1).toList();
    final comparable = [
      for (final e in sorted)
        if (compareDockVersions(e.version, installedVersion) != null) e,
    ];
    if (comparable.length == sorted.length) {
      return [
        for (final e in sorted)
          if (compareDockVersions(e.version, installedVersion)! > 0) e,
      ];
    }
    final at = sorted.indexWhere((e) => e.version == installedVersion);
    return at < 0 ? sorted.take(1).toList() : sorted.sublist(0, at);
  }

  /// Absent when the module does not declare `net.fetch`.
  final DockNetwork? network;
  final List<DockSchedule> schedules;
  final DockArtifact artifact;
  final DockRuntime runtime;

  /// Registered into the space's permission registry on install; see
  /// `docs/decisions/0021-modules-and-the-dock.md`'s "Dynamic permissions".
  final List<DockPermission> permissions;

  /// What the module asks the host for. The admin approves this set at
  /// install; the host refuses any host call outside it.
  final List<String> capabilities;
  final List<DockExtensionPoint> extensionPoints;

  factory DockManifest.fromJson(Map<String, dynamic> json) => DockManifest(
        id: json['id'] as String,
        name: json['name'] as String,
        version: json['version'] as String,
        summary: json['summary'] as String,
        author: json['author'] as String?,
        artifact:
            DockArtifact.fromJson(json['artifact'] as Map<String, dynamic>),
        runtime: DockRuntime.fromJson(json['runtime'] as Map<String, dynamic>),
        permissions: (json['permissions'] as List<dynamic>)
            .map((p) => DockPermission.fromJson(p as Map<String, dynamic>))
            .toList(growable: false),
        capabilities: (json['capabilities'] as List<dynamic>)
            .map((c) => c as String)
            .toList(growable: false),
        extensionPoints: (json['extension_points'] as List<dynamic>)
            .map((e) => DockExtensionPoint.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        network: json['network'] == null
            ? null
            : DockNetwork.fromJson(json['network'] as Map<String, dynamic>),
        schedules: dockSchedules(json['schedules']),
        changelog: dockChangelog(json['changelog']),
        subscriptions: dockSubscriptions(json['subscriptions']),
        dataMaxMb: dockDataMaxMb(json['data']),
        dataSchema: dockDataSchema(json['data']),
        interceptors: dockHooks(json['interceptors']),
        permissionHooks: dockHooks(json['permission_hooks']),
        reviewDigest: json['review_digest'] as String?,
        callAudio: json['call_audio'] == null
            ? null
            : DockCallAudio.fromJson(
                json['call_audio'] as Map<String, dynamic>),
        connectorPermissions: dockConnectorAsk(json),
        hostRun: dockHostRunAsk(json),
      );
}
