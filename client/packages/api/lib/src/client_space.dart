// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Who may create an account on this deployment.
enum JoinPolicy {
  /// A valid invite code is required. The default, and what every deployment
  /// keeps unless somebody changes it.
  invite,

  /// Anyone who can reach the server may register. A code is still accepted,
  /// so an invite granting a role keeps working.
  open;

  String get wire => name;

  /// An unrecognised policy reads as [invite]. A server that grows a third
  /// value must not read as open to a client that has never heard of it.
  static JoinPolicy parse(String value) =>
      value == 'open' ? JoinPolicy.open : JoinPolicy.invite;
}

/// Deployment-wide settings, as `/space/settings` reports them.
///
/// Declared here rather than in `models_totp.dart` because [JoinPolicy] is
/// declared here, and that file is a separate library which cannot see it.
class SpaceSettings {
  const SpaceSettings({required this.joinPolicy, required this.totpPolicy});

  final JoinPolicy joinPolicy;
  final TotpPolicy totpPolicy;

  /// `totp_policy` is absent from a server older than decision 0048, which
  /// reads as [TotpPolicy.optional] rather than failing the whole settings load
  /// over a field the rest of the screen does not need.
  factory SpaceSettings.fromJson(Map<String, dynamic> json) => SpaceSettings(
        joinPolicy: JoinPolicy.parse(json['join_policy'] as String),
        totpPolicy: TotpPolicy.parse(
          json['totp_policy'] as String? ?? TotpPolicy.optional.wire,
        ),
      );
}

/// Deployment-wide settings. Both calls require MANAGE_SERVER.
extension SlimmApiSpace on SlimmApi {
  Future<SpaceSettings> spaceSettings() async {
    final json = await _send('GET', '/space/settings');
    return SpaceSettings.fromJson(json as Map<String, dynamic>);
  }

  /// Writes whichever of [joinPolicy] and [totpPolicy] is given and leaves the
  /// other alone.
  ///
  /// A field is omitted rather than echoed back when the caller does not mean
  /// to change it: the server writes only what is present, so a screen holding
  /// a stale snapshot cannot overwrite the operator's other choice. At least
  /// one is required.
  Future<SpaceSettings> setSpaceSettings({
    JoinPolicy? joinPolicy,
    TotpPolicy? totpPolicy,
  }) async {
    assert(
      joinPolicy != null || totpPolicy != null,
      'a settings PATCH must carry at least one field',
    );
    final json = await _send(
      'PATCH',
      '/space/settings',
      body: {
        if (joinPolicy != null) 'join_policy': joinPolicy.wire,
        if (totpPolicy != null) 'totp_policy': totpPolicy.wire,
      },
    );
    return SpaceSettings.fromJson(json as Map<String, dynamic>);
  }

  Future<SpaceAnalytics> spaceAnalytics() async {
    final json = await _send('GET', '/space/analytics');
    return SpaceAnalytics._fromJson(json as Map<String, dynamic>);
  }

  Future<SpaceAnalytics> setSpaceAnalyticsEnabled(bool enabled) async {
    final json = await _send(
      'PATCH',
      '/space/analytics',
      body: {'enabled': enabled},
    );
    return SpaceAnalytics._fromJson(json as Map<String, dynamic>);
  }

  Future<int> spaceMessageRetentionDays() async {
    final json = await _send('GET', '/space/retention');
    return (json as Map<String, dynamic>)['retention_days'] as int;
  }

  Future<int> setSpaceMessageRetentionDays(int days) async {
    final json = await _send(
      'PATCH',
      '/space/retention',
      body: {'retention_days': days},
    );
    return (json as Map<String, dynamic>)['retention_days'] as int;
  }

  Future<int> spaceCanvasObjectCap() async {
    final json = await _send('GET', '/space/canvas-cap');
    return (json as Map<String, dynamic>)['object_cap'] as int;
  }

  Future<int> setSpaceCanvasObjectCap(int cap) async {
    final json = await _send(
      'PATCH',
      '/space/canvas-cap',
      body: {'object_cap': cap},
    );
    return (json as Map<String, dynamic>)['object_cap'] as int;
  }

  Future<int> spaceScreenShareMaxHeight() async {
    final json = await _send('GET', '/space/screen-share');
    return (json as Map<String, dynamic>)['max_height'] as int;
  }

  Future<int> setSpaceScreenShareMaxHeight(int maxHeight) async {
    final json = await _send(
      'PATCH',
      '/space/screen-share',
      body: {'max_height': maxHeight},
    );
    return (json as Map<String, dynamic>)['max_height'] as int;
  }

  /// Operator-visible storage usage and sweep health. Always computes -
  /// there is no on/off toggle the way `spaceAnalytics` has.
  Future<SpaceStorage> fetchSpaceStorage() async {
    final json = await _send('GET', '/space/storage');
    return SpaceStorage._fromJson(json as Map<String, dynamic>);
  }
}

/// One calendar day's Space-wide message count, UTC, zero-filled for a day
/// with none.
class AnalyticsDayCount {
  const AnalyticsDayCount({required this.date, required this.count});

  final String date;
  final int count;

  factory AnalyticsDayCount._fromJson(Map<String, dynamic> json) =>
      AnalyticsDayCount(
        date: json['date'] as String,
        count: json['count'] as int,
      );
}

/// One recorded reading of the server process's own memory.
class AnalyticsMemorySample {
  const AnalyticsMemorySample({
    required this.sampledAt,
    required this.rssBytes,
  });

  final int sampledAt;
  final int rssBytes;

  factory AnalyticsMemorySample._fromJson(Map<String, dynamic> json) =>
      AnalyticsMemorySample(
        sampledAt: json['sampled_at'] as int,
        rssBytes: json['rss_bytes'] as int,
      );
}

/// The Space-wide usage stats [SpaceAnalytics] carries when recording is on.
/// Every field here is an aggregate: nothing carries a per-member breakdown,
/// by design - see `docs/decisions/0008-space-analytics.md`.
class AnalyticsStats {
  const AnalyticsStats({
    required this.totalMessages,
    required this.memberCount,
    required this.channelCount,
    required this.attachmentBytes,
    required this.messagesByDay,
    required this.activeHours,
    required this.memorySamples,
  });

  final int totalMessages;
  final int memberCount;
  final int channelCount;
  final int attachmentBytes;
  final List<AnalyticsDayCount> messagesByDay;

  /// 24 entries, index 0-23 as UTC hour-of-day, summed across every author
  /// over the trailing 30-day window.
  final List<int> activeHours;
  final List<AnalyticsMemorySample> memorySamples;

  factory AnalyticsStats._fromJson(Map<String, dynamic> json) => AnalyticsStats(
        totalMessages: json['total_messages'] as int,
        memberCount: json['member_count'] as int,
        channelCount: json['channel_count'] as int,
        attachmentBytes: json['attachment_bytes'] as int,
        messagesByDay: (json['messages_by_day'] as List<dynamic>)
            .map((e) => AnalyticsDayCount._fromJson(e as Map<String, dynamic>))
            .toList(),
        activeHours: (json['active_hours'] as List<dynamic>)
            .map((e) => e as int)
            .toList(),
        memorySamples: (json['memory_samples'] as List<dynamic>)
            .map((e) =>
                AnalyticsMemorySample._fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One member's own attachment byte total, from [SpaceAnalytics.memberStorage].
///
/// Deliberately not part of [AnalyticsStats]: that class's own doc promises
/// never to name a member, and this is the one field on the response that
/// does, on purpose, for storage stewardship rather than usage surveillance.
/// See `docs/decisions/0008-space-analytics.md`.
class MemberAttachmentUsage {
  const MemberAttachmentUsage({
    required this.userId,
    required this.attachmentBytes,
  });

  final String userId;

  /// Every attachment this member has personally uploaded, by content hash.
  /// Two members who each uploaded identical bytes are each charged the
  /// full size: this is what a member contributed, not a share of
  /// deduplicated disk use.
  final int attachmentBytes;

  factory MemberAttachmentUsage._fromJson(Map<String, dynamic> json) =>
      MemberAttachmentUsage(
        userId: json['user_id'] as String,
        attachmentBytes: json['attachment_bytes'] as int,
      );
}

/// `stats` and `memberStorage` are both null whenever [enabled] is false:
/// recording never ran, so there is nothing to derive or report, not even
/// retroactively. The two are siblings, never nested, on purpose: see
/// [MemberAttachmentUsage]'s own doc for the privacy line between them.
class SpaceAnalytics {
  const SpaceAnalytics({required this.enabled, this.stats, this.memberStorage});

  final bool enabled;
  final AnalyticsStats? stats;
  final List<MemberAttachmentUsage>? memberStorage;

  factory SpaceAnalytics._fromJson(Map<String, dynamic> json) => SpaceAnalytics(
        enabled: json['enabled'] as bool,
        stats: json['stats'] == null
            ? null
            : AnalyticsStats._fromJson(json['stats'] as Map<String, dynamic>),
        memberStorage: json['member_storage'] == null
            ? null
            : (json['member_storage'] as List<dynamic>)
                .map((e) =>
                    MemberAttachmentUsage._fromJson(e as Map<String, dynamic>))
                .toList(),
      );
}

/// One channel's share of attachment storage, from [SpaceStorage.topChannels].
class ChannelStorage {
  const ChannelStorage({
    required this.channelId,
    required this.name,
    required this.attachmentBytes,
  });

  final String channelId;
  final String name;
  final int attachmentBytes;

  factory ChannelStorage._fromJson(Map<String, dynamic> json) => ChannelStorage(
        channelId: json['channel_id'] as String,
        name: json['name'] as String,
        attachmentBytes: json['attachment_bytes'] as int,
      );
}

/// One background sweep's last recorded run, from [SpaceStorage.sweeps].
class SweepStatus {
  const SweepStatus({
    required this.name,
    required this.lastRunAt,
    required this.lastReclaimed,
  });

  /// Stable snake_case identifier: `token`, `attachments`, `canvas_ops`, or
  /// `message_retention`.
  final String name;
  final int lastRunAt;

  /// What that pass reclaimed, in whatever unit that sweep counts (rows
  /// removed, files freed) - sweep-specific, not always bytes.
  final int lastReclaimed;

  factory SweepStatus._fromJson(Map<String, dynamic> json) => SweepStatus(
        name: json['name'] as String,
        lastRunAt: json['last_run_at'] as int,
        lastReclaimed: json['last_reclaimed'] as int,
      );
}

/// Operator-visible storage usage and sweep health, from
/// [SlimmApiSpace.fetchSpaceStorage]. Always computed; unlike
/// [SpaceAnalytics] there is no toggle to turn this off.
class SpaceStorage {
  const SpaceStorage({
    required this.databaseBytes,
    required this.databaseReclaimableBytes,
    required this.attachmentBytes,
    required this.topChannels,
    required this.sweeps,
  });

  /// The database file's logical size, from SQLite's own page count.
  final int databaseBytes;

  /// How much of [databaseBytes] a `VACUUM` could reclaim.
  final int databaseReclaimableBytes;

  /// The same total [SpaceAnalytics.stats]' `attachmentBytes` reports.
  final int attachmentBytes;

  /// Channels holding the most attachment bytes, heaviest first. DMs and
  /// threads are excluded.
  final List<ChannelStorage> topChannels;

  /// Every background sweep that has recorded at least one run.
  final List<SweepStatus> sweeps;

  factory SpaceStorage._fromJson(Map<String, dynamic> json) => SpaceStorage(
        databaseBytes: json['database_bytes'] as int,
        databaseReclaimableBytes: json['database_reclaimable_bytes'] as int,
        attachmentBytes: json['attachment_bytes'] as int,
        topChannels: (json['top_channels'] as List<dynamic>)
            .map((e) => ChannelStorage._fromJson(e as Map<String, dynamic>))
            .toList(),
        sweeps: (json['sweeps'] as List<dynamic>)
            .map((e) => SweepStatus._fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
