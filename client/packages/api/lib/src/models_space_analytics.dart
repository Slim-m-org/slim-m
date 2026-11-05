// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space-wide analytics and storage-health models.
library;

/// One calendar day's Space-wide message count, UTC, zero-filled for a day
/// with none.
class AnalyticsDayCount {
  const AnalyticsDayCount({required this.date, required this.count});

  final String date;
  final int count;

  factory AnalyticsDayCount.fromJson(Map<String, dynamic> json) =>
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

  factory AnalyticsMemorySample.fromJson(Map<String, dynamic> json) =>
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

  factory AnalyticsStats.fromJson(Map<String, dynamic> json) => AnalyticsStats(
        totalMessages: json['total_messages'] as int,
        memberCount: json['member_count'] as int,
        channelCount: json['channel_count'] as int,
        attachmentBytes: json['attachment_bytes'] as int,
        messagesByDay: (json['messages_by_day'] as List<dynamic>)
            .map((e) => AnalyticsDayCount.fromJson(e as Map<String, dynamic>))
            .toList(),
        activeHours: (json['active_hours'] as List<dynamic>)
            .map((e) => e as int)
            .toList(),
        memorySamples: (json['memory_samples'] as List<dynamic>)
            .map((e) =>
                AnalyticsMemorySample.fromJson(e as Map<String, dynamic>))
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

  factory MemberAttachmentUsage.fromJson(Map<String, dynamic> json) =>
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

  factory SpaceAnalytics.fromJson(Map<String, dynamic> json) => SpaceAnalytics(
        enabled: json['enabled'] as bool,
        stats: json['stats'] == null
            ? null
            : AnalyticsStats.fromJson(json['stats'] as Map<String, dynamic>),
        memberStorage: json['member_storage'] == null
            ? null
            : (json['member_storage'] as List<dynamic>)
                .map((e) =>
                    MemberAttachmentUsage.fromJson(e as Map<String, dynamic>))
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

  factory ChannelStorage.fromJson(Map<String, dynamic> json) => ChannelStorage(
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

  factory SweepStatus.fromJson(Map<String, dynamic> json) => SweepStatus(
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
    required this.backup,
  });

  /// The nightly backup the backup container last reported.
  final SpaceBackupStatus backup;

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

  factory SpaceStorage.fromJson(Map<String, dynamic> json) => SpaceStorage(
        databaseBytes: json['database_bytes'] as int,
        databaseReclaimableBytes: json['database_reclaimable_bytes'] as int,
        attachmentBytes: json['attachment_bytes'] as int,
        topChannels: (json['top_channels'] as List<dynamic>)
            .map((e) => ChannelStorage.fromJson(e as Map<String, dynamic>))
            .toList(),
        sweeps: (json['sweeps'] as List<dynamic>)
            .map((e) => SweepStatus.fromJson(e as Map<String, dynamic>))
            .toList(),
        backup:
            SpaceBackupStatus.fromJson(json['backup'] as Map<String, dynamic>),
      );
}

/// How the newest nightly backup went, from [SpaceStorage.backup].
enum BackupState { notConfigured, never, verified, failed, unreadable }

class SpaceBackupStatus {
  const SpaceBackupStatus({
    required this.state,
    required this.stale,
    this.error,
    this.verifiedAt,
    this.verifiedBytes,
  });

  final BackupState state;

  /// The last verified backup is older than 48 hours.
  final bool stale;

  /// What the newest run failed with, when [state] is [BackupState.failed].
  final String? error;

  /// Epoch milliseconds of the last backup that passed its restore drill.
  final int? verifiedAt;
  final int? verifiedBytes;

  factory SpaceBackupStatus.fromJson(Map<String, dynamic> json) =>
      SpaceBackupStatus(
        state: switch (json['state']) {
          'not_configured' => BackupState.notConfigured,
          'verified' => BackupState.verified,
          'failed' => BackupState.failed,
          'unreadable' => BackupState.unreadable,
          _ => BackupState.never,
        },
        stale: json['stale'] as bool? ?? false,
        error: json['error'] as String?,
        verifiedAt: json['verified_at'] as int?,
        verifiedBytes: json['verified_bytes'] as int?,
      );
}

/// One operator alert. An unknown [kind] is shown by its [detail].
class AdminAlert {
  const AdminAlert({
    required this.kind,
    required this.subject,
    required this.detail,
    required this.raisedAt,
    this.resolvedAt,
  });

  final String kind;
  final String subject;
  final String detail;
  final int raisedAt;

  /// Null while the condition lasts.
  final int? resolvedAt;

  bool get isOpen => resolvedAt == null;

  factory AdminAlert.fromJson(Map<String, dynamic> json) => AdminAlert(
        kind: json['kind'] as String,
        subject: json['subject'] as String? ?? '',
        detail: json['detail'] as String,
        raisedAt: json['raised_at'] as int,
        resolvedAt: json['resolved_at'] as int?,
      );
}

/// The alert list and the caller's mute, from [SlimmApiSpace.fetchAdminAlerts].
class AdminAlerts {
  const AdminAlerts({required this.alerts, required this.muted});

  final List<AdminAlert> alerts;
  final bool muted;

  List<AdminAlert> get open => [
        for (final a in alerts)
          if (a.isOpen) a
      ];

  factory AdminAlerts.fromJson(Map<String, dynamic> json) => AdminAlerts(
        alerts: (json['alerts'] as List<dynamic>)
            .map((e) => AdminAlert.fromJson(e as Map<String, dynamic>))
            .toList(),
        muted: json['muted'] as bool? ?? false,
      );
}
