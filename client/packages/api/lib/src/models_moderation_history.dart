// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `GET /reports/history`'s merged feed: a resolved report or a
/// `moderation_audit_log` entry, newest first. Split out of
/// `models_moderation.dart` for the line budget.
///
/// See docs/decisions/0015-moderation-audit-log.md for why these are two
/// distinct shapes rather than one table: a live-state table only ever
/// answers "what is true now", so history is a separate, append-only record.
library;

import 'models.dart';

/// One entry in the merged feed. [cursorKind] and [id] are exactly what
/// `SlimmApiModeration.moderationHistory`'s `afterKind`/`afterId` expect back,
/// so a caller builds its next page's cursor from the last item on this one
/// rather than tracking the two kinds separately.
sealed class ModerationHistoryItem {
  const ModerationHistoryItem();

  /// Null for a `kind` this client does not know. A kind has no generic
  /// form: a row of it carries no cursor the server would accept back, so
  /// [SlimmApiModeration.moderationHistory] drops it instead of failing the
  /// page.
  static ModerationHistoryItem? tryFromJson(Map<String, dynamic> json) =>
      switch (json['kind']) {
        'resolved_report' => ResolvedReportHistoryEntry.fromJson(json),
        'audit_log' => AuditLogHistoryEntry.fromJson(json),
        _ => null,
      };

  /// This item's own id: a UUID for a resolved report, a decimal row-id
  /// string for an audit-log entry.
  String get id;

  /// Which kind [id] is - `resolved_report` or `audit_log`.
  String get cursorKind;

  /// The event time this item sorts by: a resolved report's `resolvedAt`, an
  /// audit entry's `createdAt`.
  int get eventTime;
}

/// A report that has been closed, carried into the history feed. Never an
/// open report - see `SlimmApiModeration.moderationHistory`'s own doc.
class ResolvedReportHistoryEntry extends ModerationHistoryItem {
  const ResolvedReportHistoryEntry({
    required this.id,
    required this.subjectKind,
    required this.subjectId,
    required this.reason,
    required this.createdAt,
    required this.resolvedAt,
    this.reporterId,
    this.channelId,
    this.snapshot,
    this.subjectAuthorId,
    this.resolvedBy,
    this.resolution,
  });

  @override
  final String id;

  /// Null once the reporter's account has been anonymized.
  final String? reporterId;
  final ReportSubject subjectKind;
  final String subjectId;

  /// Null for a user report, which has no channel of its own.
  final String? channelId;
  final String reason;

  /// The reported content as it stood at filing time. Absent for a user
  /// report.
  final String? snapshot;
  final String? subjectAuthorId;

  /// Unix milliseconds; when the report was filed.
  final int createdAt;

  /// Unix milliseconds; when a moderator closed it.
  final int resolvedAt;

  /// Null once that moderator's account has been anonymized.
  final String? resolvedBy;
  final ReportResolution? resolution;

  @override
  String get cursorKind => 'resolved_report';

  @override
  int get eventTime => resolvedAt;

  factory ResolvedReportHistoryEntry.fromJson(Map<String, dynamic> json) =>
      ResolvedReportHistoryEntry(
        id: json['id'] as String,
        reporterId: json['reporter_id'] as String?,
        subjectKind: ReportSubject.parse(json['subject_kind'] as String),
        subjectId: json['subject_id'] as String,
        channelId: json['channel_id'] as String?,
        reason: json['reason'] as String,
        snapshot: json['snapshot'] as String?,
        subjectAuthorId: json['subject_author_id'] as String?,
        createdAt: json['created_at'] as int,
        resolvedAt: json['resolved_at'] as int,
        resolvedBy: json['resolved_by'] as String?,
        resolution: _resolutionOf(json['resolution']),
      );
}

ReportResolution? _resolutionOf(Object? raw) => switch (raw) {
      'resolved' => ReportResolution.resolved,
      'dismissed' => ReportResolution.dismissed,
      _ => null,
    };

/// What an audit row records: the five moderation acts plus the account,
/// bot, webhook and nickname events the server also writes into
/// `moderation_audit_log`. [unknown] is the documented fallback for an action
/// a newer server adds, so the feed keeps loading and shows a generic row.
enum AuditLogAction {
  remove,
  restore,
  timeout,
  timeoutCleared,
  messagesDeleted,
  botCreate,
  botRevoke,
  botPermissionGrant,
  webhookCreate,
  webhookRevoke,
  webhookRotate,
  totpCleared,
  accountDelete,
  resetCodeIssue,
  nicknameSet,
  nicknameClear,
  unknown;

  static AuditLogAction parse(String wire) => switch (wire) {
        'remove' => AuditLogAction.remove,
        'restore' => AuditLogAction.restore,
        'timeout' => AuditLogAction.timeout,
        'timeout_cleared' => AuditLogAction.timeoutCleared,
        'messages_deleted' => AuditLogAction.messagesDeleted,
        'bot_create' => AuditLogAction.botCreate,
        'bot_revoke' => AuditLogAction.botRevoke,
        'bot_permission_grant' => AuditLogAction.botPermissionGrant,
        'webhook_create' => AuditLogAction.webhookCreate,
        'webhook_revoke' => AuditLogAction.webhookRevoke,
        'webhook_rotate' => AuditLogAction.webhookRotate,
        'totp_cleared' => AuditLogAction.totpCleared,
        'account_delete' => AuditLogAction.accountDelete,
        'reset_code_issue' => AuditLogAction.resetCodeIssue,
        'nickname_set' => AuditLogAction.nicknameSet,
        'nickname_clear' => AuditLogAction.nicknameClear,
        _ => AuditLogAction.unknown,
      };
}

/// One `moderation_audit_log` row, carried into the history feed.
class AuditLogHistoryEntry extends ModerationHistoryItem {
  const AuditLogHistoryEntry({
    required this.id,
    required this.subjectId,
    required this.action,
    required this.createdAt,
    this.actorId,
    this.reason,
    this.until,
  });

  /// The audit row's own id, as a decimal string.
  @override
  final String id;

  /// Null once the actor's account has been anonymized.
  final String? actorId;
  final String subjectId;
  final AuditLogAction action;
  final String? reason;

  /// Unix milliseconds; the deadline a `timeout` set or a `timeoutCleared`
  /// cut short. Null for every other action.
  final int? until;

  /// Unix milliseconds.
  final int createdAt;

  @override
  String get cursorKind => 'audit_log';

  @override
  int get eventTime => createdAt;

  factory AuditLogHistoryEntry.fromJson(Map<String, dynamic> json) =>
      AuditLogHistoryEntry(
        id: json['id'] as String,
        actorId: json['actor_id'] as String?,
        subjectId: json['subject_id'] as String,
        action: AuditLogAction.parse(json['action'] as String),
        reason: json['reason'] as String?,
        until: json['until'] as int?,
        createdAt: json['created_at'] as int,
      );
}
