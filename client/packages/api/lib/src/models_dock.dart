// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock: browsing, installing, and enabling modules from the addons
/// marketplace. See `docs/decisions/0021-modules-and-the-dock.md` for the
/// module system this is the client half of - slim ships the host and the
/// marketplace, never a module's own behavior.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

import 'models_dock_activity.dart';
import 'models_dock_changelog.dart';
import 'models_dock_platform.dart';

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

/// Where a module's verified artifact lives, and the hash the install call
/// checks it against before anything runs.
class DockArtifact {
  const DockArtifact({
    required this.kind,
    required this.path,
    required this.sha256,
  });

  final String kind;
  final String path;

  /// 64 lowercase hex characters.
  final String sha256;

  factory DockArtifact.fromJson(Map<String, dynamic> json) => DockArtifact(
        kind: json['kind'] as String,
        path: json['path'] as String,
        sha256: json['sha256'] as String,
      );
}

/// Resource ceilings the host enforces on a module's runtime. Any field can
/// be absent, meaning that backend applies its own default rather than the
/// manifest naming one.
class DockLimits {
  const DockLimits({this.memoryMb, this.wallMs, this.fuel});

  final int? memoryMb;
  final int? wallMs;

  /// The WASM fuel budget metering CPU use; see decision 0021's runtime
  /// section for why this replaces a wall-clock-only limit.
  final int? fuel;

  factory DockLimits.fromJson(Map<String, dynamic> json) => DockLimits(
        memoryMb: json['memory_mb'] as int?,
        wallMs: json['wall_ms'] as int?,
        fuel: json['fuel'] as int?,
      );
}

/// Which host-provided runtime a module needs, and its resource ceilings. A
/// module never ships or installs a runtime; it only names one slim already
/// offers.
class DockRuntime {
  const DockRuntime({required this.backend, required this.limits});

  final String backend;
  final DockLimits limits;

  factory DockRuntime.fromJson(Map<String, dynamic> json) => DockRuntime(
        backend: json['backend'] as String,
        limits: DockLimits.fromJson(json['limits'] as Map<String, dynamic>),
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

List<DockSchedule> _schedules(Object? json) =>
    ((json as List<dynamic>?) ?? const [])
        .map((s) => DockSchedule.fromJson(s as Map<String, dynamic>))
        .toList(growable: false);

/// A module's full manifest, as `GET /space/dock/modules/{id}` returns it: the
/// permissions it will add and the capabilities it asks for, shown before an
/// admin ever installs it.
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
    this.reviewDigest,
  });

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
        schedules: _schedules(json['schedules']),
        changelog: dockChangelog(json['changelog']),
        subscriptions: dockSubscriptions(json['subscriptions']),
        dataMaxMb: dockDataMaxMb(json['data']),
        dataSchema: dockDataSchema(json['data']),
        reviewDigest: json['review_digest'] as String?,
      );
}

/// One module this space has installed, from the Dock's lifecycle calls and
/// `GET /space/dock/installed`.
class InstalledDockModule {
  const InstalledDockModule({
    required this.id,
    required this.name,
    required this.version,
    required this.artifactSha256,
    required this.approvedCapabilities,
    this.approvedHostCapabilities = const [],
    required this.extensionPoints,
    required this.enabled,
    required this.installedAt,
    this.sourceRepo,
    this.networkHosts = const [],
    this.localNetworkApproved = false,
    this.schedules = const [],
    this.botUserId,
    this.scheduleChannelId,
    this.runStats,
    this.storage,
    this.declaresSettings = false,
    this.subscriptions = const [],
    this.dataSchema,
    this.consecutiveFailures = 0,
    this.disabledReason,
    this.eventsDropped = 0,
  });

  /// Event kinds it was installed to receive.
  final List<String> subscriptions;

  /// The data store it was installed with; null when it declared none.
  final DockDataSchema? dataSchema;

  /// Failed event or scheduled runs in a row; the host turns it off at five.
  final int consecutiveFailures;

  /// Why the host turned it off; null until it did.
  final String? disabledReason;

  /// Pushed events its queue dropped because it fell behind.
  final int eventsDropped;

  /// Whether it declares settings an admin can fill.
  final bool declaresSettings;

  /// How each command has run lately; only `GET /space/dock/installed` fills it.
  final List<DockRunStat>? runStats;

  /// What its `kv.store` holds; only `GET /space/dock/installed` fills it.
  final DockStorage? storage;

  final String id;
  final String name;
  final String version;

  /// The hosts the admin approved with `net.fetch`; empty without it.
  final List<String> networkHosts;
  final bool localNetworkApproved;
  final List<DockSchedule> schedules;

  /// The module's own principal, present once `schedule` is approved.
  final String? botUserId;

  /// Where its scheduled runs post; null until an admin chooses.
  final String? scheduleChannelId;

  /// The community source's `owner/repo` it was installed from, or null for
  /// the official source.
  final String? sourceRepo;
  final String artifactSha256;
  final List<String> approvedCapabilities;

  /// The host capabilities an admin approved this module to use (`kv.store`,
  /// `message.post`). Empty for a module installed before that approval
  /// existed: nothing was granted then and nothing is now.
  final List<String> approvedHostCapabilities;

  /// Which commands this installed module offers, and the permission each
  /// needs, as recorded at its last install - not re-fetched from the
  /// registry, so this stays accurate even if the upstream manifest has
  /// since changed.
  final List<DockExtensionPoint> extensionPoints;

  /// Off by default: installing never runs a module, a separate enable call
  /// does.
  final bool enabled;

  /// Unix milliseconds.
  final int installedAt;

  factory InstalledDockModule.fromJson(Map<String, dynamic> json) =>
      InstalledDockModule(
        id: json['id'] as String,
        name: json['name'] as String,
        version: json['version'] as String,
        artifactSha256: json['artifact_sha256'] as String,
        approvedCapabilities: (json['approved_capabilities'] as List<dynamic>)
            .map((c) => c as String)
            .toList(growable: false),
        approvedHostCapabilities:
            ((json['approved_host_capabilities'] as List<dynamic>?) ?? const [])
                .map((c) => c as String)
                .toList(growable: false),
        extensionPoints: (json['extension_points'] as List<dynamic>)
            .map((e) => DockExtensionPoint.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        enabled: json['enabled'] as bool,
        installedAt: json['installed_at'] as int,
        sourceRepo: json['source_repo'] as String?,
        networkHosts: ((json['network_hosts'] as List<dynamic>?) ?? const [])
            .map((h) => h as String)
            .toList(growable: false),
        localNetworkApproved: json['local_network_approved'] as bool? ?? false,
        schedules: _schedules(json['schedules']),
        botUserId: json['bot_user_id'] as String?,
        scheduleChannelId: json['schedule_channel_id'] as String?,
        runStats: (json['run_stats'] as List<dynamic>?)
            ?.map((s) => DockRunStat.fromJson(s as Map<String, dynamic>))
            .toList(growable: false),
        storage: json['storage'] == null
            ? null
            : DockStorage.fromJson(json['storage'] as Map<String, dynamic>),
        declaresSettings: dockDeclaresSettings(json['settings']),
        subscriptions: dockSubscriptions(json['subscriptions']),
        dataSchema: dockDataSchema(json['data']),
        consecutiveFailures: json['consecutive_failures'] as int? ?? 0,
        disabledReason: json['disabled_reason'] as String?,
        eventsDropped: json['events_dropped'] as int? ?? 0,
      );
}
