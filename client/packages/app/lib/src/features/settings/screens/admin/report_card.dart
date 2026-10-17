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

import '../../../../format.dart';
import '../../../../permissions.dart';
import '../../../../providers/admin_providers.dart';
import '../../providers/display_preferences.dart';
import '../../../emoji/providers/emoji_catalog_provider.dart';
import '../../../members/providers/member_presence.dart' show membersProvider;
import '../../../../providers/providers.dart';
import '../../../members/providers/reports_controller.dart';
import '../../../members/providers/user_profiles.dart';
import '../../../channels/widgets/channel_rail.dart' show selectedChannelId;
import '../../../../widgets/confirm_dialog.dart';
import '../../../messages/widgets/message_jump.dart';
import '../../../messages/widgets/message_text.dart';
import '../../../members/widgets/moderation_unavailable_caption.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_value_row.dart';
import '../../../channels/screens/channel_screen.dart'
    show knownRoleNamesFrom, knownUsernamesFrom;
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
    final report = widget.report;
    final profiles = ref.watch(batchProfilesControllerProvider);
    // A reconnect clears the cache and a rename evicts an id; ask again for what went missing.
    ref.listen(batchProfilesControllerProvider, (_, _) => _requestProfiles());
    final facts = _ReportFacts(
      report: report,
      profiles: profiles,
      meId: ref.watch(meProvider).valueOrNull?.id,
      permissions: ref.watch(myPermissionsProvider),
      channelReachable: _channelReachable ?? false,
    );

    return SettingsSectionCard(
      title: switch (report.subjectKind) {
        api.ReportSubject.message => 'Reported message',
        api.ReportSubject.ephemeralMessage => 'Reported private message',
        api.ReportSubject.user => 'Reported user',
      },
      children: [
        _subjectBlock(facts),
        SettingsValueRow(
          label: 'Reporter',
          value: reporterLabel(report.reporterId, profiles),
        ),
        SettingsValueRow(
          label: 'Reported',
          value: formatDateTime(
            report.createdAt,
            use24Hour: watchUse24Hour(ref, context),
          ),
        ),
        // Only shown when it would clarify something: without either bit, no quick actions was already the ordinary reason.
        if (facts.isSelf && facts.canModerateAnyone)
          const SettingsCardBlock(
            children: [
              ModerationUnavailableCaption(
                "This report names you - you can't time yourself out or remove "
                'yourself.',
              ),
            ],
          ),
        if (facts.hasQuickActions)
          SettingsCardBlock(children: [_quickActions(facts)]),
        _resolveBlock(),
      ],
    );
  }

  Widget _subjectBlock(_ReportFacts facts) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final report = widget.report;
    final snapshot = report.snapshot;
    return SettingsCardBlock(
      gap: AppSpacing.s8,
      children: [
        // 'Subject' rather than repeating the card's own title.
        ReportLabeledValue(label: facts.subjectLabel, value: facts.targetName),
        Text(
          report.reason,
          style: AppText.body.copyWith(color: tokens.textPrimary),
        ),
        if (facts.isPrivateBotReport)
          Text(
            'The server kept no copy. This is the text the reporter says they were shown.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        if (snapshot != null) _snapshotBox(tokens, snapshot),
      ],
    );
  }

  Widget _snapshotBox(AppTokens tokens, String snapshot) {
    final members = ref.watch(membersProvider);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s8),
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      // Bounded and scrolling, not clipped, so one long paste cannot grow past the rest.
      constraints: const BoxConstraints(maxHeight: 160),
      child: SingleChildScrollView(
        child: MessageBody(
          content: snapshot,
          knownUsernames: knownUsernamesFrom(members),
          knownRoleNames: knownRoleNamesFrom(members),
          customEmoji: ref.watch(customEmojiIndexProvider),
        ),
      ),
    );
  }

  Widget _quickActions(_ReportFacts facts) {
    final report = widget.report;
    final targetUserId = facts.targetUserId;
    return ReportQuickActions(
      busy: _busy,
      jumpEnabled: facts.canJump ? facts.jumpEnabled : null,
      onJump: facts.canJump ? _jump : null,
      onDelete: facts.canDeleteMessage
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
      onRemove: facts.canRemove
          ? () => unawaited(
              _runQuickAction(
                (g) => removeReportedAuthor(
                  context,
                  ref,
                  g,
                  userId: targetUserId!,
                  name: facts.targetName,
                  reportId: report.id,
                ),
              ),
            )
          : null,
      onTimeOut: facts.canTimeOut
          ? (d) => unawaited(
              _runQuickAction(
                (g) => timeOutReportedAuthor(
                  ref,
                  g,
                  userId: targetUserId!,
                  duration: d,
                  reportId: report.id,
                ),
              ),
            )
          : null,
    );
  }

  Widget _resolveBlock() => SettingsCardBlock(
    gap: AppSpacing.s12,
    children: [
      if (actionError != null)
        AppErrorState(message: actionError!, onDismiss: clearActionError),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: AppSpacing.s8,
        runSpacing: AppSpacing.s8,
        children: [
          AppButton(
            label: 'Dismiss',
            icon: AppIcons.dismiss,
            disabled: _busy,
            onPressed: () => _resolve(api.ReportResolution.dismissed),
          ),
          AppButton(
            label: 'Resolve',
            icon: AppIcons.check,
            variant: AppButtonVariant.primary,
            disabled: _busy,
            onPressed: () => _resolve(api.ReportResolution.resolved),
          ),
        ],
      ),
    ],
  );
}

/// What a report and the viewer's permissions allow, derived once per build.
class _ReportFacts {
  _ReportFacts({
    required this.report,
    required this.profiles,
    required this.meId,
    required this.permissions,
    required this.channelReachable,
  });

  final api.Report report;
  final Map<String, api.UserProfile?> profiles;
  final String? meId;
  final int permissions;
  final bool channelReachable;

  bool get isMessageReport => report.subjectKind == api.ReportSubject.message;
  bool get isPrivateBotReport =>
      report.subjectKind == api.ReportSubject.ephemeralMessage;
  bool get _hasAuthor => isMessageReport || isPrivateBotReport;

  String? get targetUserId =>
      _hasAuthor ? report.subjectAuthorId : report.subjectId;

  String get targetName => _hasAuthor
      ? authorHeadline(report.subjectAuthorId, profiles)
      : subjectHeadline(report.subjectId, profiles);

  String get subjectLabel {
    if (isMessageReport) return 'Reported author';
    return isPrivateBotReport ? 'Reported bot' : 'Subject';
  }

  bool get isSelf => targetUserId != null && targetUserId == meId;

  bool get canJump => isMessageReport && report.channelId != null;
  bool get jumpEnabled => canJump && channelReachable;

  // This report's own channel figure, never mine - a DM's never carries it.
  bool get canDeleteMessage =>
      isMessageReport &&
      (report.channelPermissions?.hasPermission(Perm.manageMessages) ?? false);

  bool get _canActOnTarget => targetUserId != null && !isSelf;
  bool get canTimeOut =>
      _canActOnTarget && permissions.hasPermission(Perm.kickMembers);
  bool get canRemove =>
      _canActOnTarget && permissions.hasPermission(Perm.banMembers);
  bool get canModerateAnyone =>
      permissions.hasPermission(Perm.kickMembers) ||
      permissions.hasPermission(Perm.banMembers);

  bool get hasQuickActions =>
      canJump || canDeleteMessage || canTimeOut || canRemove;
}
