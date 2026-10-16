// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two personal settings sections about the account itself: blocked users,
/// and sign-out or deletion. `DevicesSection` split out to
/// `devices_section.dart`, re-exported here so existing callers are unaffected.
///
/// Account deletion is reachable in two taps from the main surface, which the
/// app stores require and which is also just correct: an account you cannot
/// leave is a trap.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/blocks_controller.dart';
import '../providers/providers.dart';
import '../providers/push_controller.dart';
import '../providers/sync_controller.dart';
import '../providers/user_profiles.dart';
import '../providers/voice_controller.dart';
import 'confirm_dialog.dart';
import 'reauth_sheet.dart';
import 'run_guarded.dart';
import 'settings_danger_card.dart';
import 'settings_detail_row.dart';
import 'settings_empty.dart';
import 'settings_section_header.dart';

export 'devices_section.dart' show DevicesSection, devicesProvider;

/// The blocked list, and the one place a block can be undone.
///
/// Says what blocking really does rather than the old blanket promise: messages,
/// reactions and typing are hidden and no notification arrives, and the person
/// is still in the member list, which is where the row that offers this lives.
const accountDeletionDescription =
    'Permanently removes you and signs out every device.';

class BlockedSection extends ConsumerWidget {
  const BlockedSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(blocksProvider);

    return SettingsSectionCard(
      flush: true,
      title: 'People you blocked',
      description: 'You stop seeing and hearing from them; they are not told.',
      children: [
        if (!blocks.settled)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: LinearProgressIndicator(),
          )
        else if (blocks.error case final error?)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              message: 'Could not load the block list.',
              detail: error,
              onRetry: () => ref.read(blocksProvider.notifier).refresh(),
            ),
          )
        else if (blocks.ids.isEmpty)
          const SettingsEmptyState(
            icon: AppIcons.revoke,
            title: 'Nobody is blocked',
            detail:
                'People you block will be listed here, with a way to unblock them.',
          )
        else
          for (final userId in blocks.ids) _BlockedRow(userId: userId),
      ],
    );
  }
}

/// One blocked person, by name.
///
/// The id is resolved through the same profile fetch every message author goes
/// through. It used to render the raw 36-character uuid, which reads as
/// corruption rather than as a person somebody chose to block, and gives no way
/// to tell two of them apart.
class _BlockedRow extends ConsumerStatefulWidget {
  const _BlockedRow({required this.userId});

  final String userId;

  @override
  ConsumerState<_BlockedRow> createState() => _BlockedRowState();
}

class _BlockedRowState extends ConsumerState<_BlockedRow>
    with GuardedActionState<_BlockedRow> {
  Future<void> _unblock() async {
    await guard(
      whatFailed: 'unblock that user',
      action: () => ref.read(blocksProvider.notifier).unblock(widget.userId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(userProfileProvider(widget.userId));
    // A deleted account resolves to null, and its id is all there is left of it.
    final name =
        profile.valueOrNull?.displayName ?? profile.valueOrNull?.username;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsDetailRow(
          icon: AppIcons.account,
          title: name ?? 'Deleted account',
          detail: name == null ? widget.userId : null,
          monoDetail: true,
          trailing: AppButton(
            label: 'Unblock',
            size: AppButtonSize.sm,
            onPressed: _unblock,
          ),
        ),
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s8,
            ),
            child: AppErrorState(
              message: actionError!,
              onDismiss: clearActionError,
            ),
          ),
      ],
    );
  }
}

class AccountSection extends ConsumerStatefulWidget {
  const AccountSection({super.key});

  @override
  ConsumerState<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends ConsumerState<AccountSection> {
  /// A failed deletion stays on screen until it is retried or dismissed: it
  /// is the most consequential action here, and a toast that floats away
  /// leaves the user with no idea why nothing changed.
  String? _deleteError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s12),
      child: SettingsDangerCard(
        title: 'Delete account',
        message: accountDeletionDescription,
        // The ellipsis says a confirmation follows, as every other
        // destructive action in this app does.
        action: AppButton(
          label: 'Delete account...',
          variant: AppButtonVariant.danger,
          size: AppButtonSize.sm,
          onPressed: () => _confirmDeletion(context, ref),
        ),
        error: _deleteError == null
            ? null
            : AppErrorState(
                message:
                    'Could not delete the account. Your account is '
                    'unchanged and you are still signed in.',
                detail: _deleteError,
                onRetry: () => _confirmDeletion(context, ref),
                onDismiss: () => setState(() => _deleteError = null),
              ),
      ),
    );
  }

  /// Deletion is irreversible, so it asks plainly and states what survives.
  /// Saying "your messages stay" up front is more honest than a vague warning,
  /// and it is the thing people are actually surprised by afterwards.
  ///
  /// Push is unregistered before the delete for the same reason sign-out does
  /// it: the device's push key has to go while the session that registered it
  /// is still valid, so it is not left to be inherited by whichever account
  /// signs into this device next.
  ///
  /// A failed delete deliberately leaves the session alone. Unlike sign-out,
  /// deletion is not safe to assume happened just because the request failed,
  /// and clearing it would orphan the account with no session left to retry
  /// from. The failure still has to reach the screen, or the user is stranded
  /// with no idea why nothing updates any more; sync and push, stopped ahead
  /// of the request, are restarted on that same failure for the same reason.
  Future<void> _confirmDeletion(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Delete this account?',
      message:
          'Your devices, read state, and blocks are erased, and the username '
          'becomes available again.\n\n'
          'Messages you posted in shared channels stay, so conversations do not '
          'develop holes, but they will no longer be attributed to you.\n\n'
          'This cannot be undone.',
      confirmLabel: 'Delete permanently',
      cancelLabel: 'Keep my account',
    );
    if (!confirmed || !context.mounted) return;

    final bool needsCode;
    try {
      needsCode = (await ref.read(apiProvider).totpStatus()).enabled;
    } on api.ApiException catch (e) {
      if (mounted) setState(() => _deleteError = e.message);
      return;
    }
    if (!context.mounted) return;
    setState(() => _deleteError = null);
    await showReauthSheet(
      context,
      title: 'Confirm it is you',
      description: needsCode
          ? 'Enter your password and a current code to delete this account.'
          : 'Enter your password to delete this account.',
      submitLabel: 'Delete permanently',
      askForCode: needsCode,
      dangerous: true,
      onSubmit: (password, code) => _deleteWith(ref, password, code),
    );
  }

  /// Returns the sentence to keep the proof sheet open on, which is only a
  /// refused password or code. Any other failure closes the sheet and lands in
  /// [_deleteError], where it stays until retried or dismissed.
  Future<String?> _deleteWith(
    WidgetRef ref,
    String password,
    String? code,
  ) async {
    /// All three read before the request, and sync and push restarted
    /// without consulting [mounted]: what they undo is app-global, so
    /// navigating away from this screen while the delete is in flight must
    /// not be what leaves sync stopped and push unregistered for the rest of
    /// the process. Only the error text is this widget's, and only that needs
    /// the guard. The call is deliberately not rejoined on failure: being in
    /// one is an active choice, not state to restore behind somebody's back.
    final voice = ref.read(voiceControllerProvider.notifier);
    final sync = ref.read(syncControllerProvider.notifier);
    final push = ref.read(pushControllerProvider.notifier);
    // Otherwise a live call keeps heartbeating a session about to be deleted.
    await voice.leave();
    await sync.stop();
    await push.unregister();
    try {
      await ref.read(apiProvider).deleteAccount(password: password, code: code);
      return null;
    } on api.ApiException catch (e) {
      /// Not on a 401: there the session is already gone, cleared by the
      /// refresh path before this catch runs, so restarting would race the
      /// sign-out into an exponential retry loop against a signed-out
      /// session and register push with no session to bind it to.
      if (e is! api.UnauthorizedException) {
        unawaited(sync.start());
        unawaited(push.register());
      }
      final refused =
          e is api.ForbiddenException ||
          e is api.BadRequestException ||
          e is api.RateLimitedException;
      if (refused) return reauthFailure(e);
      if (mounted) setState(() => _deleteError = e.message);
      return null;
    }
  }
}

/// Signing out, on its own so it can be pinned to the settings nav's footer
/// rather than sitting in a pane.
///
/// It is the one action here that is not about changing a setting, which is why
/// it belongs on the frame: you do not go looking for it inside a category.
/// Deliberately no longer beside "Delete account" - one is routine and the
/// other is irreversible, and a routine action next to a destructive one is
/// how a mis-tap happens.
class SignOutRow extends ConsumerWidget {
  const SignOutRow({super.key});

  /// Push is unregistered before the session goes, or this device keeps waking
  /// for an account that is no longer signed in on it.
  ///
  /// A live call is left first for the same reason: `voiceControllerProvider`
  /// is app-lifetime, not scoped to a session, so nothing else would ever
  /// stop it POSTing a heartbeat, on a cleared session, for the rest of the
  /// process's life.
  static Future<void> signOut(WidgetRef ref) async {
    await ref.read(voiceControllerProvider.notifier).leave();
    await ref.read(syncControllerProvider.notifier).stop();
    await ref.read(pushControllerProvider.notifier).unregister();
    try {
      await ref.read(apiProvider).logout();
    } on api.ApiException {
      // The session may already be gone; clear locally either way.
      ref.read(sessionProvider).clear();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      label: 'Sign out',
      leading: Icon(
        AppIcons.signOut,
        size: AppSizes.icon16,
        color: tokens.dangerText,
      ),
      onTap: () => signOut(ref),
    );
  }
}
