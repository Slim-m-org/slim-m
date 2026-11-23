// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module a space has installed. Split out of models_dock.dart to stay under
/// the line budget.
library;

import 'models_dock.dart';
import 'models_dock_activity.dart';
import 'models_dock_platform.dart';

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
    this.declaresMemberBadge = false,
    this.declaresProfileSection = false,
    this.subscriptions = const [],
    this.dataSchema,
    this.interceptors = const [],
    this.permissionHooks = const [],
    this.consecutiveFailures = 0,
    this.disabledReason,
    this.eventsDropped = 0,
    this.queueDepth = 0,
    this.fuelLimit = 0,
    this.connectorPermissions,
    this.connectorToken,
  });

  /// For a connector, the core permission bits the admin approved; null for a WASM module.
  final int? connectorPermissions;
  bool get isConnector => connectorPermissions != null;

  /// A connector's token, only in the install answer that created it.
  final String? connectorToken;

  /// Event kinds it was installed to receive.
  final List<String> subscriptions;

  /// The hooks it was installed with; empty from a server that does not send them.
  final List<DockHookDecl> interceptors;
  final List<DockHookDecl> permissionHooks;

  /// The data store it was installed with; null when it declared none.
  final DockDataSchema? dataSchema;

  /// Whether it holds every hook [wanted] declares, reading no more.
  bool coversHooksOf(DockManifest wanted) =>
      dockHooksCover(interceptors, wanted.interceptors) &&
      dockHooksCover(permissionHooks, wanted.permissionHooks);

  /// Failed event or scheduled runs in a row; the host turns it off at five.
  final int consecutiveFailures;

  /// Why the host turned it off; null until it did.
  final String? disabledReason;

  /// Pushed events its queue dropped because it fell behind.
  final int eventsDropped;

  /// Pushed events waiting for it right now; only `GET /space/dock/installed` fills it.
  final int queueDepth;

  /// The fuel one run may burn, which each command's fuel is read against; 0 from an older server.
  final int fuelLimit;

  /// Whether it declares settings an admin can fill.
  final bool declaresSettings;

  /// Whether it declares a `member.badge` slot, shown beside names in the member list.
  final bool declaresMemberBadge;

  /// Whether it declares a `profile.section` slot, shown on profile cards.
  final bool declaresProfileSection;

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
        schedules: dockSchedules(json['schedules']),
        botUserId: json['bot_user_id'] as String?,
        scheduleChannelId: json['schedule_channel_id'] as String?,
        runStats: (json['run_stats'] as List<dynamic>?)
            ?.map((s) => DockRunStat.fromJson(s as Map<String, dynamic>))
            .toList(growable: false),
        storage: json['storage'] == null
            ? null
            : DockStorage.fromJson(json['storage'] as Map<String, dynamic>),
        declaresSettings: dockDeclaresSettings(json['settings']),
        declaresMemberBadge: dockDeclaresMemberBadge(json['slots']),
        declaresProfileSection: dockDeclaresProfileSection(json['slots']),
        subscriptions: dockSubscriptions(json['subscriptions']),
        dataSchema: dockDataSchema(json['data']),
        interceptors: dockHooks(json['interceptors']),
        permissionHooks: dockHooks(json['permission_hooks']),
        consecutiveFailures: json['consecutive_failures'] as int? ?? 0,
        disabledReason: json['disabled_reason'] as String?,
        eventsDropped: json['events_dropped'] as int? ?? 0,
        queueDepth: json['queue_depth'] as int? ?? 0,
        fuelLimit: json['fuel_limit'] as int? ?? 0,
        connectorPermissions: json['connector_permissions'] as int?,
        connectorToken: json['connector_token'] as String?,
      );
}
