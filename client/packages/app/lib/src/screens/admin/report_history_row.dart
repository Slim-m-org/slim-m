// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One row of the moderation-history feed: a resolved report or a
/// `moderation_audit_log` entry, named "who did what to whom, when" - the
/// four fields decision 0015 built the audit trail to answer. Split out of
/// `report_history_pane.dart` to keep that file under budget, the same split
/// `report_card.dart`/`report_card_labels.dart` already makes.
///
/// Names actor and subject through `report_card_labels.dart`'s own helpers:
/// [reporterLabel] fits any id that reads "a deleted account" once
/// anonymized, not only a report's reporter, and [subjectHeadline] /
/// [authorHeadline] are the exact pair `ReportCard` uses to name a message
/// report's author versus a user report's subject.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../format.dart';
import '../../providers/display_preferences.dart';
import '../../providers/user_profiles.dart';
import '../../widgets/settings_entity_row.dart';
import 'report_card_labels.dart'
    show authorHeadline, reporterLabel, subjectHeadline;

class ReportHistoryRow extends ConsumerWidget {
  const ReportHistoryRow({super.key, required this.item});

  final api.ModerationHistoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(batchProfilesControllerProvider);
    final use24Hour = watchUse24Hour(ref, context);
    return switch (item) {
      final api.AuditLogHistoryEntry entry => _auditRow(
        entry,
        profiles,
        use24Hour,
      ),
      final api.ResolvedReportHistoryEntry entry => _reportRow(
        entry,
        profiles,
        use24Hour,
      ),
    };
  }

  Widget _auditRow(
    api.AuditLogHistoryEntry entry,
    Map<String, api.UserProfile?> profiles,
    bool use24Hour,
  ) {
    final (variant, label) = _auditBadge(entry.action);
    return SettingsEntityRow(
      headline: subjectHeadline(entry.subjectId, profiles),
      badge: AppBadge(variant: variant, label: label),
      details: [
        SettingsEntityDetail(
          '${reporterLabel(entry.actorId, profiles)} · '
          '${formatDateTime(entry.createdAt, use24Hour: use24Hour)}',
        ),
        if (entry.until case final until?)
          SettingsEntityDetail(
            'Until ${formatDateTime(until, use24Hour: use24Hour)}',
          ),
        if (entry.reason case final reason?)
          SettingsEntityDetail(reason, wrap: true),
      ],
    );
  }

  Widget _reportRow(
    api.ResolvedReportHistoryEntry entry,
    Map<String, api.UserProfile?> profiles,
    bool use24Hour,
  ) {
    final hasAuthor = entry.subjectKind != api.ReportSubject.user;
    final subjectName = hasAuthor
        ? authorHeadline(entry.subjectAuthorId, profiles)
        : subjectHeadline(entry.subjectId, profiles);
    final (variant, label) = _reportBadge(entry.resolution);
    return SettingsEntityRow(
      headline: subjectName,
      badge: AppBadge(variant: variant, label: label),
      details: [
        SettingsEntityDetail(
          '${reporterLabel(entry.resolvedBy, profiles)} · '
          '${formatDateTime(entry.resolvedAt, use24Hour: use24Hour)}',
        ),
        SettingsEntityDetail(entry.reason, wrap: true),
      ],
    );
  }
}

(AppBadgeVariant, String) _auditBadge(
  api.AuditLogAction action,
) => switch (action) {
  api.AuditLogAction.remove => (AppBadgeVariant.warn, 'Removed'),
  api.AuditLogAction.restore => (AppBadgeVariant.tag, 'Restored'),
  api.AuditLogAction.timeout => (AppBadgeVariant.warn, 'Timed out'),
  api.AuditLogAction.timeoutCleared => (AppBadgeVariant.tag, 'Timeout cleared'),
  api.AuditLogAction.messagesDeleted => (
    AppBadgeVariant.warn,
    'Messages deleted',
  ),
  api.AuditLogAction.botCreate => (AppBadgeVariant.tag, 'Bot created'),
  api.AuditLogAction.botRevoke => (AppBadgeVariant.warn, 'Bot revoked'),
  api.AuditLogAction.botPermissionGrant => (
    AppBadgeVariant.tag,
    'Bot permission granted',
  ),
  api.AuditLogAction.webhookCreate => (AppBadgeVariant.tag, 'Webhook created'),
  api.AuditLogAction.webhookRevoke => (AppBadgeVariant.warn, 'Webhook revoked'),
  api.AuditLogAction.webhookRotate => (AppBadgeVariant.tag, 'Webhook rotated'),
  api.AuditLogAction.totpCleared => (
    AppBadgeVariant.warn,
    'Two-factor cleared',
  ),
  api.AuditLogAction.accountDelete => (AppBadgeVariant.warn, 'Account deleted'),
  api.AuditLogAction.resetCodeIssue => (
    AppBadgeVariant.tag,
    'Reset code issued',
  ),
  api.AuditLogAction.nicknameSet => (AppBadgeVariant.tag, 'Nickname set'),
  api.AuditLogAction.nicknameClear => (AppBadgeVariant.tag, 'Nickname cleared'),
  api.AuditLogAction.unknown => (AppBadgeVariant.tag, 'Other action'),
};

(AppBadgeVariant, String) _reportBadge(api.ReportResolution? resolution) =>
    switch (resolution) {
      api.ReportResolution.resolved => (AppBadgeVariant.tag, 'Resolved'),
      api.ReportResolution.dismissed => (AppBadgeVariant.tag, 'Dismissed'),
      null => (AppBadgeVariant.tag, 'Closed'),
    };
