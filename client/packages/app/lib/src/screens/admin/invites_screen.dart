// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Invite management: `GET/POST /invites` and `DELETE /invites/{code}`.
/// Requires CREATE_INVITE.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../api_failure.dart';
import '../../format.dart';
import '../../providers/admin_providers.dart';
import '../../providers/display_preferences.dart';
import '../../invite_link.dart';
import '../../permissions.dart';
import '../../providers/providers.dart';
import '../../providers/toasts.dart';
import '../../routing/routes.dart';
import '../../widgets/join_policy_row.dart';
import '../../widgets/totp_policy_row.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_entity_row.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import '../../widgets/confirm_dialog.dart';
import 'invite_role_grant_picker.dart';
import '../../action_labels.dart';

const _expiryOptions = <(String, Duration?)>[
  ('Never', null),
  ('1 day', Duration(days: 1)),
  ('7 days', Duration(days: 7)),
  ('30 days', Duration(days: 30)),
];

class InvitesScreen extends StatelessWidget {
  const InvitesScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Invites',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: InvitesPane(),
  );
}

/// The invite list and create card, embeddable as a Space settings pane as
/// well as routed.
class InvitesPane extends ConsumerWidget {
  const InvitesPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(myPermissionsProvider);
    final canInvite = permissions.hasPermission(Perm.createInvite);
    final canManageServer = permissions.hasPermission(Perm.manageServer);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Who may join sits above the codes that let them in; see JoinPolicyRow.
        if (canManageServer) ...[
          const SettingsSectionCard(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [JoinPolicyRow(), TotpPolicyRow()],
          ),
          if (canInvite) const SizedBox(height: AppSpacing.s16),
        ],
        if (canInvite) ...[
          const _CreateInviteCard(),
          const SizedBox(height: AppSpacing.s16),
          const _InviteList(),
        ],
      ],
    );
  }
}

/// Every invite in force, for whoever may issue one.
class _InviteList extends ConsumerWidget {
  const _InviteList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invites = ref.watch(invitesProvider);
    return AppAsyncView<List<api.Invite>>(
      value: AppAsyncState(data: invites.valueOrNull, error: invites.error),
      center: false,
      errorMessage: 'Could not load invites.',
      onRetry: () => ref.invalidate(invitesProvider),
      isEmpty: (list) => list.isEmpty,
      emptyMessage: 'No invites yet.',
      data: (context, list) => SettingsSectionCard(
        title: 'Invites',
        children: [
          for (final invite in list)
            _InviteRow(key: ValueKey(invite.code), invite: invite),
        ],
      ),
    );
  }
}

class _CreateInviteCard extends ConsumerStatefulWidget {
  const _CreateInviteCard();

  @override
  ConsumerState<_CreateInviteCard> createState() => _CreateInviteCardState();
}

class _CreateInviteCardState extends ConsumerState<_CreateInviteCard> {
  final _maxUses = TextEditingController();
  int _expiryIndex = 0;
  bool _submitting = false;
  String? _roleGrant;
  api.Invite? _created;
  String? _error;

  @override
  void dispose() {
    _maxUses.dispose();
    super.dispose();
  }

  /// Null while the field is empty (deliberately unlimited) or a whole number
  /// of at least one, which is all the server accepts. Anything else must
  /// block submission rather than let [int.tryParse]'s null quietly become
  /// "unlimited" too.
  String? get _maxUsesError {
    final text = _maxUses.text.trim();
    if (text.isEmpty) return null;
    final uses = int.tryParse(text);
    if (uses != null && uses >= 1) return null;
    return 'Enter a number above 0, or leave blank for unlimited.';
  }

  Future<void> _create() async {
    if (_maxUsesError != null) {
      setState(() {});
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final maxUsesText = _maxUses.text.trim();
    final maxUses = maxUsesText.isEmpty ? null : int.tryParse(maxUsesText);
    final duration = _expiryOptions[_expiryIndex].$2;
    final expiresAt = duration == null
        ? null
        : DateTime.now().add(duration).millisecondsSinceEpoch;
    try {
      final invite = await ref
          .read(apiProvider)
          .createInvite(
            maxUses: maxUses,
            expiresAt: expiresAt,
            roleGrant: _roleGrant,
          );
      if (context.mounted) ref.invalidate(invitesProvider);
      if (!mounted) return;
      setState(() {
        _created = invite;
        _maxUses.clear();
        _expiryIndex = 0;
        _roleGrant = null;
      });
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = describeApiFailure('create the invite', e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      title: 'New invite',
      children: [
        if (_created != null) ...[
          _CreatedInviteCallout(
            invite: _created!,
            onDismiss: () => setState(() => _created = null),
          ),
          const SizedBox(height: AppSpacing.s12),
        ],
        AppInput(
          controller: _maxUses,
          placeholder: 'Uses allowed (blank for unlimited)',
          semanticLabel: 'Uses allowed',
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          errorText: _maxUsesError,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s12),
        AppSegmentedControl.inline(
          semanticLabel: 'Invite expiry',
          options: [
            for (final option in _expiryOptions)
              AppSegmentedOption(label: option.$1),
          ],
          selectedIndex: _expiryIndex,
          onSegmentSelected: (i) => setState(() => _expiryIndex = i),
        ),
        InviteRoleGrantPicker(
          selected: _roleGrant,
          onChanged: (id) => setState(() => _roleGrant = id),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.s12),
          AppErrorState(message: _error!),
        ],
        const SizedBox(height: AppSpacing.s12),
        AppButton(
          label: _submitting ? 'Creating...' : ActionLabels.createInvite,
          icon: AppIcons.invite,
          variant: AppButtonVariant.primary,
          full: true,
          disabled: _submitting,
          onPressed: _create,
        ),
      ],
    );
  }
}

/// Copies the whole invite - server and code in one string - which is what
/// somebody being invited actually needs. See `invite_link.dart` for why it
/// is a `slimm://` link rather than an https one.
void _copyInviteLink(WidgetRef ref, String code) {
  Clipboard.setData(
    ClipboardData(
      text: buildInviteLink(server: ref.read(serverUrlProvider), code: code),
    ),
  );
  ref
      .read(toastsProvider.notifier)
      .show('Invite link copied.', severity: AppToastSeverity.success);
}

/// Copies the bare code, still worth keeping: reading six characters down a
/// phone is sometimes the right move, and a link is unreadable aloud.
void _copyInviteCode(WidgetRef ref, String code) {
  Clipboard.setData(ClipboardData(text: code));
  ref
      .read(toastsProvider.notifier)
      .show('Invite code copied.', severity: AppToastSeverity.success);
}

class _CreatedInviteCallout extends ConsumerWidget {
  const _CreatedInviteCallout({required this.invite, required this.onDismiss});

  final api.Invite invite;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCallout(
      tone: AppCalloutTone.accent,
      child: Row(
        children: [
          Expanded(child: Text(invite.code, style: AppText.code)),
          AppIconButton(
            icon: AppIcons.link,
            semanticLabel: 'Copy invite link',
            size: AppIconButtonSize.sm,
            onPressed: () => _copyInviteLink(ref, invite.code),
          ),
          AppIconButton(
            icon: AppIcons.copy,
            semanticLabel: 'Copy invite code',
            size: AppIconButtonSize.sm,
            onPressed: () => _copyInviteCode(ref, invite.code),
          ),
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Dismiss',
            size: AppIconButtonSize.sm,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// Which state badge an invite gets, or null for a usable code with nothing
/// to flag.
///
/// Order matters when more than one applies. Revoked always wins: it is a
/// deliberate admin action, not an arithmetic fact, and stays true regardless
/// of uses or expiry. Fully used is checked before expiry because the uses
/// pair already on the row (`10/10 uses`) is the more concrete explanation;
/// an invite that is both spent and past its date is still spent first. A
/// server that reports `usable: false` for neither reason (a future case
/// this client cannot yet name) still gets a label rather than none.
(AppBadgeVariant, String)? _inviteBadge(api.Invite invite, int nowMs) {
  if (invite.revoked) return (AppBadgeVariant.warn, 'Revoked');
  if (invite.usable) return null;
  if (invite.maxUses != null && invite.uses >= invite.maxUses!) {
    return (AppBadgeVariant.tag, 'Fully used');
  }
  if (invite.expiresAt != null && invite.expiresAt! <= nowMs) {
    return (AppBadgeVariant.tag, 'Expired');
  }
  return (AppBadgeVariant.tag, 'Unusable');
}

/// What to say about the role an invite grants, or null for one that grants
/// none. Distinguishes "still loading" from "granted, but that role is gone"
/// so a resolved-but-missing id does not silently read as no grant at all.
String? _roleGrantLabel(String? roleId, AsyncValue<List<api.Role>> roles) {
  if (roleId == null) return null;
  return switch (roles) {
    AsyncData(:final value) =>
      'Grants ${value.where((r) => r.id == roleId).firstOrNull?.name ?? 'a since-removed role'}',
    _ => 'Grants a role',
  };
}

class _InviteRow extends ConsumerStatefulWidget {
  const _InviteRow({super.key, required this.invite});

  final api.Invite invite;

  @override
  ConsumerState<_InviteRow> createState() => _InviteRowState();
}

class _InviteRowState extends ConsumerState<_InviteRow>
    with GuardedActionState {
  bool _busy = false;

  Future<void> _revoke() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Revoke this invite?',
      message:
          'Anyone holding "${widget.invite.code}" will no longer be '
          'able to redeem it. This cannot be undone.',
      confirmLabel: 'Revoke',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'revoke the invite',
      action: () => ref.read(apiProvider).revokeInvite(widget.invite.code),
    );
    if (!mounted) return;
    if (ok) {
      ref.invalidate(invitesProvider);
      return;
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final invite = widget.invite;
    final usesLabel = invite.maxUses == null
        ? '${invite.uses} uses'
        : '${invite.uses}/${invite.maxUses} uses';
    final expiryLabel = invite.expiresAt == null
        ? 'Never expires'
        : 'Expires ${formatDateTime(invite.expiresAt!, use24Hour: watchUse24Hour(ref, context))}';
    final badge = _inviteBadge(invite, DateTime.now().millisecondsSinceEpoch);
    // Watched only for a role-granting invite, the one row needing the roles list at all.
    final roleGrantLabel = invite.roleGrant == null
        ? null
        : _roleGrantLabel(invite.roleGrant, ref.watch(rolesProvider));

    return SettingsEntityRow(
      headline: invite.code,
      headlineStyle: AppText.code,
      badge: badge == null
          ? null
          : AppBadge(variant: badge.$1, label: badge.$2),
      details: [
        SettingsEntityDetail('$usesLabel · $expiryLabel'),
        if (roleGrantLabel != null)
          SettingsEntityDetail(roleGrantLabel, tone: tokens.accent),
      ],
      // A revoked invite reserves the revoke slot rather than dropping it.
      actions: [
        AppIconButton(
          icon: AppIcons.link,
          semanticLabel: 'Copy invite link',
          onPressed: () => _copyInviteLink(ref, invite.code),
        ),
        AppIconButton(
          icon: AppIcons.copy,
          semanticLabel: 'Copy invite code',
          onPressed: () => _copyInviteCode(ref, invite.code),
        ),
        if (!invite.revoked)
          AppIconButton(
            icon: AppIcons.revoke,
            semanticLabel: 'Revoke invite',
            variant: AppIconButtonVariant.danger,
            onPressed: _busy ? null : _revoke,
          )
        else
          null,
      ],
      error: actionError,
      onErrorRetry: _busy ? null : _revoke,
      onErrorDismiss: clearActionError,
    );
  }
}
