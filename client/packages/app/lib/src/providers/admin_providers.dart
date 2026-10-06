// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Data for the moderation and administration screens: the reports queue,
/// invite management, roles, and channel permission overwrites.
///
/// Each list is a plain autoDispose future, matching [devicesProvider] and
/// [blocksProvider] in `settings_screen.dart`: nothing here is long-lived
/// state, so a screen refetches on entry and a mutation invalidates the one
/// list it touched.
///
/// The member list for the role-assignment picker is deliberately not here: it
/// is `membersProvider` from `member_presence.dart`, reused rather than
/// redefined, because it is the same `GET /members` page the rail header and
/// member pane already show and a second copy would invalidate independently
/// of theirs.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'channel_permissions.dart';
import 'live_events.dart';
import 'providers.dart';

/// The caller's own base (deployment-level) permission bitmask, or 0 while
/// [meProvider] is loading or failed: every gate here reads as "show
/// nothing" rather than "show everything" until proven otherwise.
final myPermissionsProvider = Provider<int>(
  (ref) => ref.watch(meProvider).valueOrNull?.permissions ?? 0,
);

/// Every invite, in the order the server returns them.
final invitesProvider = FutureProvider.autoDispose<List<api.Invite>>(
  (ref) => ref.watch(apiProvider).listInvites(),
);

/// Everyone removed from the Space, newest first. The only list that still
/// names them: `GET /members` deliberately drops them.
final removedMembersProvider =
    FutureProvider.autoDispose<List<api.SpaceRemoval>>(
      (ref) => ref.watch(apiProvider).listRemovedMembers(),
    );

/// Every bot in the deployment, including revoked ones.
final botsProvider = FutureProvider.autoDispose<List<api.Bot>>(
  (ref) => ref.watch(apiProvider).listBots(),
);

/// Every webhook in the deployment, newest first.
final webhooksProvider = FutureProvider.autoDispose<List<api.Webhook>>(
  (ref) => ref.watch(apiProvider).listWebhooks(),
);

/// Every role.
final rolesProvider = FutureProvider.autoDispose<List<api.Role>>(
  (ref) => ref.watch(apiProvider).listRoles(),
);

/// Every permission overwrite currently set on one channel: what the
/// permissions grid renders as tri-state cells. Invalidated below alongside
/// [channelPermissionsProvider] whenever an [api.OverwriteChanged] names
/// this channel.
final channelOverwritesProvider = FutureProvider.autoDispose
    .family<List<api.ChannelOverwrite>, String>(
      (ref, channelId) =>
          ref.watch(apiProvider).getChannelOverwrites(channelId),
    );

/// Refetches [rolesProvider] and [meProvider] when a role's own definition
/// changes or a member's assignment does: either can change what a role
/// means for whoever is looking at this screen right now, and the caller's
/// own permissions besides. Watched by `HomeShell` for the whole session -
/// its only watch site used to be [RolesScreen], a MANAGE_ROLES-gated modal
/// never co-mounted with any consumer of what this invalidates, so for an
/// ordinary user none of it ever ran and a permission revoked mid-session
/// stayed visibly offered until renavigation. [RolesScreen] keeps its own
/// watch as documentation of the dependency, not as the thing keeping this
/// alive.
///
/// Also the one place [channelPermissionsProvider] and
/// [myVisibleChannelsProvider] are invalidated - see
/// docs/decisions/0011-per-channel-permissions.md. A role or role-assignment
/// change invalidates both bare, since either can change what the caller can
/// do (and see) in every channel at once; a self [api.MemberTimeoutChanged]
/// does the same and additionally refreshes [meProvider], closing the gap
/// where a moderator timed out mid-session kept a stale reading until some
/// unrelated refetch; an [api.OverwriteChanged] invalidates only the one
/// channel's permissions it names, plus the visible list, since an overwrite
/// can grant or revoke VIEW_CHANNEL and so change the list's membership -
/// and, if [channelOverwritesProvider] is already mounted for that channel
/// (its editor is open), that too, so a change from elsewhere never leaves
/// the editor showing a stale allow/deny pair.
final roleChangeWatcherProvider = Provider.autoDispose<void>((ref) {
  final selfId = ref.read(sessionProvider).tokens?.userId;
  // ref.invalidate on a never-watched provider mounts and fetches it.
  void refreshVisibleChannels() {
    if (ref.exists(myVisibleChannelsProvider)) {
      ref.invalidate(myVisibleChannelsProvider);
    }
  }

  final sub = ref.read(liveEventsProvider).listen((event) {
    if (event is api.RoleChanged || event is api.MemberRoleChanged) {
      ref.invalidate(rolesProvider);
      ref.invalidate(meProvider);
      ref.invalidate(channelPermissionsProvider);
      refreshVisibleChannels();
      // A module-permission grant/revoke publishes RoleChanged too.
      if (event is api.RoleChanged &&
          ref.exists(roleModulePermissionsProvider(event.roleId))) {
        ref.invalidate(roleModulePermissionsProvider(event.roleId));
      }
    } else if (event is api.MemberTimeoutChanged && event.userId == selfId) {
      ref.invalidate(meProvider);
      ref.invalidate(channelPermissionsProvider);
      refreshVisibleChannels();
    } else if (event is api.OverwriteChanged) {
      ref.invalidate(channelPermissionsProvider(event.channelId));
      if (ref.exists(channelOverwritesProvider(event.channelId))) {
        ref.invalidate(channelOverwritesProvider(event.channelId));
      }
      refreshVisibleChannels();
    }
  });
  ref.onDispose(() => unawaited(sub.cancel()));
});

/// Every custom emoji in the deployment, oldest first.
///
/// The one list, not the administration screen's own: `customEmojiIndexProvider`
/// in `emoji_catalog_provider.dart` reads it too, so uploading or removing one
/// here is what makes the next message render (or stop rendering) it. Two
/// providers over `GET /emoji` would leave a freshly uploaded emoji
/// unrenderable until relaunch.
final customEmojiProvider = FutureProvider.autoDispose<List<api.CustomEmoji>>(
  (ref) => ref.watch(apiProvider).listCustomEmoji(),
);

/// The Space usage analytics toggle and, while it is on, its stats. Off by
/// default; see `docs/decisions/0008-space-analytics.md` and
/// `screens/admin/analytics_screen.dart`.
final spaceAnalyticsProvider = FutureProvider.autoDispose<api.SpaceAnalytics>(
  (ref) => ref.watch(apiProvider).spaceAnalytics(),
);

/// The message retention window in days, `0` meaning keep forever - the
/// default, and what every deployment keeps until an admin sets one.
final spaceRetentionProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(apiProvider).spaceMessageRetentionDays(),
);

/// The per-channel canvas object cap, applied to every client. The default a
/// deployment keeps until an admin sets one is 20000; see
/// `screens/admin/canvas_cap_section.dart`.
final spaceCanvasCapProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(apiProvider).spaceCanvasObjectCap(),
);

/// The screen-share resolution ceiling, applied to every client's own
/// capture and publish parameters - see `screen_share_control.dart`. The
/// default a deployment keeps until an admin sets one is 2160; see
/// `screens/admin/screen_share_cap_section.dart`.
final spaceScreenShareCeilingProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(apiProvider).spaceScreenShareMaxHeight(),
);

/// Operator-visible storage usage and sweep health, `GET /space/storage`.
/// Always computed - unlike [spaceAnalyticsProvider] there is no toggle. See
/// `screens/admin/storage_screen.dart`.
final spaceStorageProvider = FutureProvider.autoDispose<api.SpaceStorage>(
  (ref) => ref.watch(apiProvider).fetchSpaceStorage(),
);

/// A live `GET /metrics` scrape: request latency by route, request volume by
/// rate-limit class, SQLite pool occupancy, and resident memory. See
/// `screens/admin/server_metrics_screen.dart`.
final serverMetricsProvider = FutureProvider.autoDispose<api.ServerMetrics>(
  (ref) => ref.watch(apiProvider).fetchServerMetrics(),
);

/// The module marketplace's index, plus which of those modules (if any) this
/// space has already installed - fetched together so a browse list can show
/// each entry's install state in one round trip. See
/// `docs/decisions/0021-modules-and-the-dock.md` and
/// `screens/admin/dock_screen.dart`.
class DockCatalog {
  const DockCatalog({
    required this.entries,
    required this.installed,
    this.sections = const [],
    this.sourcesFailed = false,
  });

  /// The official source's modules.
  final List<api.DockIndexEntry> entries;
  final List<api.InstalledDockModule> installed;

  /// One per community source, each loaded on its own so a broken one shows
  /// its own error and leaves the rest of the Dock alone (decision 0046).
  final List<DockSourceSection> sections;

  /// True when the source list itself could not be read.
  final bool sourcesFailed;

  /// The install record for [moduleId], or null when it is not installed.
  api.InstalledDockModule? installedFor(String moduleId) =>
      installed.where((m) => m.id == moduleId).firstOrNull;
}

/// One community source and what it lists, or that it could not be read.
class DockSourceSection {
  const DockSourceSection({
    required this.source,
    required this.entries,
    this.failed = false,
  });

  final api.DockSource source;
  final List<api.DockIndexEntry> entries;
  final bool failed;
}

final dockCatalogProvider = FutureProvider.autoDispose<DockCatalog>((
  ref,
) async {
  final client = ref.watch(apiProvider);
  final (entries, installed, sources) = await (
    client.listDockModules(),
    client.listInstalledDockModules(),
    _communitySources(client),
  ).wait;
  final communitySources = sources ?? const <api.DockSource>[];
  final sourcesFailed = sources == null;
  final sections = await Future.wait([
    for (final source in communitySources) _loadSection(client, source),
  ]);
  return DockCatalog(
    entries: entries,
    installed: installed,
    sections: sections,
    sourcesFailed: sourcesFailed,
  );
});

/// The non-official sources, or null when the list could not be read.
Future<List<api.DockSource>?> _communitySources(api.SlimmApi client) async {
  try {
    return [
      for (final s in await client.listDockSources())
        if (!s.official) s,
    ];
  } catch (_) {
    return null;
  }
}

Future<DockSourceSection> _loadSection(
  api.SlimmApi client,
  api.DockSource source,
) async {
  try {
    final entries = await client.listDockModules(source: source.id);
    return DockSourceSection(source: source, entries: entries);
  } catch (_) {
    return DockSourceSection(source: source, entries: const [], failed: true);
  }
}

/// One module's full manifest, fetched only once its row is opened - see
/// `screens/admin/dock_module_sheet.dart`.
final dockManifestProvider = FutureProvider.autoDispose
    .family<api.DockManifest, String>(
      (ref, moduleId) => ref.watch(apiProvider).getDockModule(moduleId),
    );

/// A community source's copy of one module's manifest.
final dockSourceManifestProvider = FutureProvider.autoDispose
    .family<api.DockManifest, ({String moduleId, String source})>(
      (ref, key) => ref
          .watch(apiProvider)
          .getDockModule(key.moduleId, source: key.source),
    );

/// The manifest provider for a module opened from [source], where null is the
/// official source.
AutoDisposeFutureProvider<api.DockManifest> dockManifestFor(
  String moduleId,
  String? source,
) => source == null
    ? dockManifestProvider(moduleId)
    : dockSourceManifestProvider((moduleId: moduleId, source: source));

/// Every module-scoped permission any installed module currently declares -
/// the catalog a role editor lists alongside the fixed permission bitmask.
/// See `docs/decisions/0021-modules-and-the-dock.md`.
final modulePermissionsProvider =
    FutureProvider.autoDispose<List<api.ModulePermission>>(
      (ref) => ref.watch(apiProvider).listModulePermissions(),
    );

/// The module permissions one role currently holds.
final roleModulePermissionsProvider = FutureProvider.autoDispose
    .family<List<api.GrantedModulePermission>, String>(
      (ref, roleId) => ref.watch(apiProvider).listRoleModulePermissions(roleId),
    );
