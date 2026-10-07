// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who has been removed from this Space, and letting them back in.
///
/// The only place a removed member is still nameable: `GET /members` drops
/// them, which is the point of a removal, so without this screen the act
/// would be one-way through the interface even though the server makes it
/// reversible. Requires BAN_MEMBERS, the same bit that performs it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../providers/member_presence.dart' show membersProvider;
import '../../permissions.dart';
import '../../providers/providers.dart';
import '../../routing/routes.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_entity_row.dart';
import '../../widgets/settings_notice.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import '../../widgets/settings_empty.dart';

class RemovedMembersScreen extends StatelessWidget {
  const RemovedMembersScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Removed members',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: RemovedMembersPane(),
  );
}

/// The removals list itself, embeddable as a Space settings pane as well as
/// routed.
class RemovedMembersPane extends ConsumerWidget {
  const RemovedMembersPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final removals = ref.watch(removedMembersProvider);

    return AppAsyncView<List<api.SpaceRemoval>>(
      value: AppAsyncState(data: removals.valueOrNull, error: removals.error),
      center: false,
      errorMessage: 'Could not load the removals.',
      onRetry: () => ref.invalidate(removedMembersProvider),
      // One group, so a section header would only restate the app bar.
      data: (context, list) => list.isEmpty
          ? const SettingsEmpty('Nobody has been removed from this Space.')
          : SettingsSectionCard(
              children: [
                for (final removal in list)
                  _RemovalRow(key: ValueKey(removal.userId), removal: removal),
              ],
            ),
    );
  }
}

class _RemovalRow extends ConsumerStatefulWidget {
  const _RemovalRow({super.key, required this.removal});

  final api.SpaceRemoval removal;

  @override
  ConsumerState<_RemovalRow> createState() => _RemovalRowState();
}

class _RemovalRowState extends ConsumerState<_RemovalRow>
    with GuardedActionState<_RemovalRow> {
  bool _busy = false;

  /// ADMINISTRATOR, matching the route. Someone with BAN_MEMBERS can remove
  /// and restore, which is reversible; this is not, so it asks for more.
  bool get canDeleteAccounts =>
      ref.watch(myPermissionsProvider).hasPermission(Perm.administrator);

  Future<void> _restore() async {
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'let ${widget.removal.displayName} back in',
      action: () => ref.read(apiProvider).restoreMember(widget.removal.userId),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(removedMembersProvider);
      // The member list gains a row again, so it is stale too.
      ref.invalidate(membersProvider);
    }
  }

  /// Deleting the account outright, which is the only way a removed member
  /// stops being listed here: `listRemovedMembers` skips tombstoned users.
  ///
  /// Confirmed because nothing undoes it, and worded to say what survives -
  /// what they wrote stays, anonymized, so a conversation does not develop
  /// holes when somebody is deleted.
  Future<void> _deleteAccount() async {
    final removal = widget.removal;
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Delete ${removal.displayName}?',
      message:
          'Deletes the account for good and frees @${removal.username} for '
          'somebody else to register. What they wrote stays, no longer '
          'attributed to them. This cannot be undone.',
      confirmLabel: 'Delete account',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'delete ${removal.displayName}',
      action: () => ref.read(apiProvider).deleteMemberAccount(removal.userId),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(removedMembersProvider);
      ref.invalidate(membersProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final removal = widget.removal;

    return SettingsEntityRow(
      headline: removal.displayName,
      details: [
        SettingsEntityDetail('@${removal.username}'),
        // Wrapped: the one line here a person typed, and the point of the screen.
        if (removal.reason case final reason?)
          SettingsEntityDetail(reason, wrap: true)
        else
          const SettingsAbsentValue('No reason given.'),
      ],
      actions: [
        AppButton(
          label: 'Let back in',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          onPressed: _busy ? null : _restore,
        ),
        if (canDeleteAccounts)
          AppButton(
            label: 'Delete',
            variant: AppButtonVariant.danger,
            size: AppButtonSize.sm,
            onPressed: _busy ? null : () => unawaited(_deleteAccount()),
          ),
      ],
      error: actionError,
      onErrorDismiss: clearActionError,
    );
  }
}
