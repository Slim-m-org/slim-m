// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Route paths, written by hand rather than generated.
///
/// Every navigation goes through these, so a renamed path is a compile error at
/// the call site instead of a string that silently stops matching.
library;

/// The query flag [Routes.channel] sets for `openChat`. Outside [Routes] on
/// purpose: every static string there is a route `route_reachability_test`
/// expects something to navigate to, and a query key is not one.
const _openChatQuery = 'chat';

/// The query key [Routes.personalSettingsPane] sets, kept out of [Routes] for
/// the same reason as [_openChatQuery].
const settingsPaneQuery = 'pane';

/// The id of the personal settings pane that lists signed-in devices.
const accountDevicesPane = 'account-devices';

abstract final class Routes {
  static const onboarding = '/join';
  static const signIn = '/sign-in';
  static const channels = '/channels';
  static const personalSettings = '/settings';

  /// [personalSettings] opened on one pane; see [settingsPaneQuery].
  static String personalSettingsPane(String paneId) =>
      '$personalSettings?$settingsPaneQuery=$paneId';
  static const spaceSettings = '/settings/space';

  /// [spaceSettings] opened on one pane; see [settingsPaneQuery].
  static String spaceSettingsPane(String paneId) =>
      '$spaceSettings?$settingsPaneQuery=$paneId';
  static const adminReports = '/settings/reports';
  static const adminInvites = '/settings/invites';
  static const adminRoles = '/settings/roles';

  /// One role's own Permissions/Members/Display tabs, drilled into from
  /// [adminRoles] on a phone width - the compact half of the roles pane's
  /// two-pane layout, a real route rather than a second app bar stacked
  /// inside the first.
  static String adminRole(String roleId) => '$adminRoles/$roleId';
  static const adminRemovedMembers = '/settings/removed-members';
  static const adminOverwrites = '/settings/permissions';
  static const channelSettings = '/settings/channel';
  static const adminEmoji = '/settings/emoji';
  static const adminAnalytics = '/settings/analytics';
  static const adminPerformance = '/settings/performance';
  static const adminStorage = '/settings/storage';
  static const adminServerMetrics = '/settings/server-metrics';
  static const adminDock = '/settings/dock';
  static const adminBots = '/settings/bots';
  static const adminWebhooks = '/settings/webhooks';
  static const adminAccountRecovery = '/settings/account-recovery';
  static const debugLog = '/settings/debug-log';
  static const callStats = '/settings/call-stats';

  /// One module's manifest and lifecycle, drilled into from the Dock.
  ///
  /// [source] is the community source it was listed under, so the screen
  /// reads its manifest from there; null is the official one.
  static String adminDockModule(String moduleId, {String? source}) =>
      _withSource('$adminDock/$moduleId', source);

  static String _withSource(String path, String? source) => source == null
      ? path
      : '$path?source=${Uri.encodeQueryComponent(source)}';

  /// The third level of the Dock drill-down: who may use one module. A screen
  /// rather than a sheet, so it does not scrim a Space settings modal that is
  /// already scrimming the shell.
  static String adminDockModuleAccess(String moduleId, {String? source}) =>
      _withSource('$adminDock/$moduleId/access', source);

  /// The messages of one channel. [openChat] arrives to read them: a voice
  /// channel then opens its chat and leaves its call unjoined (see
  /// `VoiceScreen.openChat`); a text channel ignores it.
  static String channel(String id, {bool openChat = false}) =>
      openChat ? '/channels/$id?$_openChatQuery=1' : '/channels/$id';

  /// One message in [channelId]: opens the channel scrolled to it and lit.
  /// Always reads rather than joins, like a jump from search (see `openChat`).
  static String message(String channelId, String messageId) =>
      '/channels/$channelId/m/$messageId';

  /// Whether [uri] was built by [channel] with `openChat`.
  static bool opensChat(Uri uri) => uri.queryParameters[_openChatQuery] == '1';

  /// The pattern go_router matches, as distinct from a built path.
  static const channelPattern = '/channels/:channelId';

  /// [message]'s pattern, relative to `/channels`. A sibling of the channel's
  /// own route rather than nested under it, or both would stack as pages.
  static const messagePattern = ':channelId/m/:messageId';

  /// A thread's own messages, opened from a message's context menu rather
  /// than from the rail - see docs/decisions/0005-threads.md.
  static String thread(String id) => '/thread/$id';

  static const threadPattern = '/thread/:channelId';
}
