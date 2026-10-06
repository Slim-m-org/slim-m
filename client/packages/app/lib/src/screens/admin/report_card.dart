// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One report in the moderation queue, split out of `reports_screen.dart` to
/// keep that file under budget. Naming the reporter and reported subject
/// lives in `report_card_labels.dart`; the quick moderation actions live in
/// `report_card_actions.dart` - both split out for the same reason.
///
/// The reported snapshot renders through the same markdown pipeline the
/// transcript uses ([MessageBody]), on purpose: a moderator judging content
/// should see what the channel actually saw, not the raw markup underneath
/// it. `report.reason` (the filer's own explanation) stays plain text - it is
/// moderator-facing metadata about the report, not the reported content.
///
/// Quick actions - jump to the message, delete it, time out or remove its
/// author - are each absent without the permission they need, never offered
/// and refused, matching `AppSegmentedOption`'s own rule.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../format.dart';
import '../../permissions.dart';
import '../../providers/admin_providers.dart';
import '../../providers/display_preferences.dart';
import '../../providers/emoji_catalog_provider.dart';
import '../../providers/member_presence.dart' show membersProvider;
import '../../providers/providers.dart';
import '../../providers/reports_controller.dart';
import '../../providers/user_profiles.dart';
import '../../widgets/channel_rail.dart' show selectedChannelId;
import '../../widgets/confirm_dialog.dart';
import '../../widgets/message_jump.dart';
import '../../widgets/message_text.dart';
import '../../widgets/moderation_unavailable_caption.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';
import '../channel_screen.dart' show knownRoleNamesFrom, knownUsernamesFrom;
import 'report_card_actions.dart';
import 'report_card_labels.dart';
import 'report_card_quick_actions.dart';

class ReportCard extends ConsumerStatefulWidget {
  const ReportCard({super.key, required this.report});

  final api.Report report;

  @override
  ConsumerState<ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends ConsumerState<ReportCard>
    with GuardedActionState<ReportCard> {
  bool _busy = false;

  /// Null while unproven; jumping stays disabled until this is true. See
  /// [_checkReachability].
  bool? _channelReachable;

  @override
  void initState() {
    super.initState();
    _requestProfiles();
    unawaited(_checkReachability());
  }

  @override
  void didUpdateWidget(covariant ReportCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.report.id != widget.report.id) {
      _channelReachable = null;
      _requestProfiles();
      unawaited(_checkReachability());
    }
  }

  /// The ids this card needs a name for: the reporter always, and the
  /// subject too when the report is about a user rather than a message.
  void _requestProfiles() {
    final report = widget.report;
    final ids = <String>{
      if (report.reporterId != null) report.reporterId!,
      if (report.subjectKind == api.ReportSubject.user) report.subjectId,
      if (report.subjectAuthorId != null) report.subjectAuthorId!,
    };
    if (ids.isEmpty) return;
    unawaited(ref.read(batchProfilesControllerProvider.notifier).resolve(ids));
  }

  /// See [reportedChannelReachable]. Left null (jump disabled) for a report
  /// with nothing to jump to at all.
  Future<void> _checkReachability() async {
    final report = widget.report;
    final channelId = report.channelId;
    if (report.subjectKind != api.ReportSubject.message || channelId == null) {
      return;
    }
    final reachable = await reportedChannelReachable(ref, channelId);
    if (!mounted || widget.report.id != report.id) return;
    setState(() => _channelReachable = reachable);
  }

  void _jump() {
    final channelId = widget.report.channelId;
    if (channelId == null) return;
    jumpToMessage(
      GoRouter.of(context),
      ref.read,
      currentChannelId: selectedChannelId(context),
      channelId: channelId,
      messageId: widget.report.subjectId,
    );
  }

  Future<void> _resolve(api.ReportResolution resolution) async {
    final verb = resolution == api.ReportResolution.resolved
        ? 'Resolve'
        : 'Dismiss';
    final confirmed = await confirmDangerousAction(
      context,
      title: '$verb this report?',
      message: resolution == api.ReportResolution.resolved
          ? 'This marks it handled and removes it from the queue. It cannot '
                'be reopened from here.'
          : 'This closes it with no action taken and removes it from the '
                'queue. It cannot be reopened from here.',
      confirmLabel: verb,
    );
    if (!confirmed || !mounted) return;
    await _runQuickAction((g) async {
      await g(
        whatFailed: 'close the report',
        action: () async {
          await ref
              .read(apiProvider)
              .resolveReport(
                reportId: widget.report.id,
                resolution: resolution,
              );
          // Without this the closed report stays in the open queue until something else reloads it.
          await ref.read(reportsControllerProvider.notifier).refresh();
        },
      );
    });
  }

  /// [action] receives this card's own [guard], not a plain closure: each of
  /// `report_card_actions.dart`'s helpers renders its own failure through it
  /// and closes the report itself, so this only owns the busy flag around it.
  Future<void> _runQuickAction(
    Future<void> Function(Guard guard) action,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    await action(guard);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final report = widget.report;
    final profiles = ref.watch(batchProfilesControllerProvider);
    final me = ref.watch(meProvider).valueOrNull;
    final mine = ref.watch(myPermissionsProvider);
    final knownUsernames = knownUsernamesFrom(ref.watch(membersProvider));
    final knownRoleNames = knownRoleNamesFrom(ref.watch(membersProvider));
    final customEmoji = ref.watch(customEmojiIndexProvider);

    final isMessageReport = report.subjectKind == api.ReportSubject.message;
    final isPrivateBotReport =
        report.subjectKind == api.ReportSubject.ephemeralMessage;
    final hasAuthor = isMessageReport || isPrivateBotReport;
    final targetUserId = hasAuthor ? report.subjectAuthorId : report.subjectId;
    final targetName = hasAuthor
        ? authorHeadline(report.subjectAuthorId, profiles)
        : subjectHeadline(report.subjectId, profiles);
    final isSelf = targetUserId != null && me != null && targetUserId == me.id;

    final canJump = isMessageReport && report.channelId != null;
    final jumpEnabled = canJump && (_channelReachable ?? false);
    // This report's own channel figure, never mine - a DM's never carries it.
    final canDeleteMessage =
        isMessageReport &&
        (report.channelPermissions?.hasPermission(Perm.manageMessages) ??
            false);
    final canTimeOut =
        targetUserId != null && !isSelf && mine.hasPermission(Perm.kickMembers);
    final canRemove =
        targetUserId != null && !isSelf && mine.hasPermission(Perm.banMembers);
    final hasQuickActions =
        canJump || canDeleteMessage || canTimeOut || canRemove;

    return SettingsSectionCard(
      title: switch (report.subjectKind) {
        api.ReportSubject.message => 'Reported message',
        api.ReportSubject.ephemeralMessage => 'Reported private message',
        api.ReportSubject.user => 'Reported user',
      },
      children: [
        ReportLabeledValue(
          // 'Subject' rather than repeating the card's own title, which AppCard(title:)'s uppercase used to hide.
          label: isMessageReport
              ? 'Reported author'
              : isPrivateBotReport
              ? 'Reported bot'
              : 'Subject',
          value: targetName,
        ),
        const SizedBox(height: AppSpacing.s8),
        Text(
          report.reason,
          style: AppText.body.copyWith(color: tokens.textPrimary),
        ),
        if (isPrivateBotReport)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: Text(
              'The server kept no copy. This is the text the reporter says they were shown.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        if (report.snapshot != null) ...[
          const SizedBox(height: AppSpacing.s8),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s8),
            decoration: BoxDecoration(
              color: tokens.surfaceSunken,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            // Bounded and scrolling, not clipped, so one long paste cannot grow past the rest.
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: MessageBody(
                content: report.snapshot!,
                knownUsernames: knownUsernames,
                knownRoleNames: knownRoleNames,
                customEmoji: customEmoji,
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s8),
        Row(
          children: [
            Text(
              'Reporter',
              style: AppText.caption.copyWith(
                color: tokens.textSecondary,
                fontWeight: AppWeights.medium,
              ),
            ),
            const SizedBox(width: AppSpacing.s4),
            // Expanded, not a bare Text: a long real display name would otherwise overflow the row.
            Expanded(
              child: Text(
                reporterLabel(report.reporterId, profiles),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
            const SizedBox(width: AppSpacing.s8),
            // Flexible so this can ellipsize rather than overflow at a large text scale.
            Flexible(
              child: Text(
                formatDateTime(
                  report.createdAt,
                  use24Hour: watchUse24Hour(ref, context),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          ],
        ),
        // Only shown when it would clarify something: without either bit, no quick actions was already the ordinary reason.
        if (isSelf &&
            (mine.hasPermission(Perm.kickMembers) ||
                mine.hasPermission(Perm.banMembers))) ...[
          const SizedBox(height: AppSpacing.s4),
          const ModerationUnavailableCaption(
            "This report names you - you can't time yourself out or remove "
            'yourself.',
          ),
        ],
        if (hasQuickActions) ...[
          const SizedBox(height: AppSpacing.s12),
          ReportQuickActions(
            busy: _busy,
            jumpEnabled: canJump ? jumpEnabled : null,
            onJump: canJump ? _jump : null,
            onDelete: canDeleteMessage
                ? () => unawaited(
                    _runQuickAction(
                      (g) => deleteReportedMessage(
                        context,
                        ref,
                        g,
                        channelId: report.channelId!,
                        messageId: report.subjectId,
                        reportId: report.id,
                      ),
                    ),
                  )
                : null,
            onRemove: canRemove
                ? () => unawaited(
                    _runQuickAction(
                      (g) => removeReportedAuthor(
                        context,
                        ref,
                        g,
                        userId: targetUserId,
                        name: targetName,
                        reportId: report.id,
                      ),
                    ),
                  )
                : null,
            onTimeOut: canTimeOut
                ? (d) => unawaited(
                    _runQuickAction(
                      (g) => timeOutReportedAuthor(
                        ref,
                        g,
                        userId: targetUserId,
                        duration: d,
                        reportId: report.id,
                      ),
                    ),
                  )
                : null,
          ),
        ],
        const SizedBox(height: AppSpacing.s12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            AppButton(
              label: 'Dismiss',
              icon: AppIcons.dismiss,
              disabled: _busy,
              onPressed: () => _resolve(api.ReportResolution.dismissed),
            ),
            const SizedBox(width: AppSpacing.s8),
            AppButton(
              label: 'Resolve',
              icon: AppIcons.check,
              variant: AppButtonVariant.primary,
              disabled: _busy,
              onPressed: () => _resolve(api.ReportResolution.resolved),
            ),
          ],
        ),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }
}
