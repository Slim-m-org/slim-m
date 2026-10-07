// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The administrator's last resort: clearing somebody's second factor
/// (`DELETE /admin/users/{userId}/totp`, `SlimmApi.clearMemberTotp`).
///
/// For a member who has lost both their authenticator and their recovery codes.
/// Deliberately not something a password reset code does on the way past: one
/// answers "I forgot my password" and this answers "I lost my authenticator",
/// and collapsing them would make the factor worth no more than one
/// administrator's say-so. Decision 0048 has the argument.
///
/// So this sheet's job is mostly to say what the act costs before it happens: it
/// signs the account out everywhere and is written to the moderation audit log,
/// where it names the administrator who did it. That is the trade the decision
/// record makes deliberately - the door exists, and it is not a quiet one.
///
/// `showAppSheet`, so a bottom sheet on a phone and a centred dialog on a
/// desktop (`docs/design/desktop-vs-mobile.md`, rule 4).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import 'run_guarded.dart';
import 'settings_notice.dart';

/// Opens the sheet for [subjectId], named [subjectName] in its title.
Future<void> showClearTotpSheet(
  BuildContext context, {
  required String subjectId,
  required String subjectName,
}) {
  return showAppSheet<void>(
    context,
    builder: (context) =>
        _ClearTotpSheet(subjectId: subjectId, subjectName: subjectName),
  );
}

/// The Moderate sub-view's row for [showClearTotpSheet], beside
/// [ResetCodeMenuItem] and built the same way, so that menu stays one line per
/// entry rather than carrying this `onTap` inline.
class ClearTotpMenuItem extends StatelessWidget {
  const ClearTotpMenuItem({
    super.key,
    required this.host,
    required this.subjectId,
    required this.subjectName,
    required this.onDone,
  });

  /// A context that outlives the popover; see `member_profile.dart`'s `host`.
  final BuildContext host;
  final String subjectId;
  final String subjectName;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => AppMenuItem(
    label: 'Clear two-factor...',
    leading: AppIcons.shieldOff,
    submenu: true,
    onTap: () {
      onDone();
      unawaited(
        showClearTotpSheet(
          host,
          subjectId: subjectId,
          subjectName: subjectName,
        ),
      );
    },
  );
}

class _ClearTotpSheet extends ConsumerStatefulWidget {
  const _ClearTotpSheet({required this.subjectId, required this.subjectName});

  final String subjectId;
  final String subjectName;

  @override
  ConsumerState<_ClearTotpSheet> createState() => _ClearTotpSheetState();
}

class _ClearTotpSheetState extends ConsumerState<_ClearTotpSheet>
    with GuardedActionState<_ClearTotpSheet> {
  bool _busy = false;
  bool _cleared = false;

  Future<void> _clear() async {
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'clear their two-factor authentication',
      action: () => ref.read(apiProvider).clearMemberTotp(widget.subjectId),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _cleared = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Clear two-factor for ${widget.subjectName}',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              _cleared
                  ? 'Done. Their password alone gets into the account again, '
                        'and they can set two-factor up afresh whenever they '
                        'want to.'
                  : 'Only for somebody who has lost both their authenticator '
                        'and their recovery codes. Make sure you actually know '
                        'who is asking - after this their password alone gets '
                        'into the account.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            if (!_cleared) ...[
              const SizedBox(height: AppSpacing.s12),
              const SettingsNotice(
                message:
                    'This signs them out on every device, and is recorded in '
                    'the moderation log against your name.',
              ),
            ],
            if (actionError != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: actionError!, onDismiss: clearActionError),
            ],
            const SizedBox(height: AppSpacing.s12),
            if (_cleared)
              AppButton(
                label: 'Done',
                variant: AppButtonVariant.primary,
                full: true,
                onPressed: () => Navigator.of(context).pop(),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Cancel',
                      variant: AppButtonVariant.ghost,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: AppButton(
                      label: _busy ? 'Clearing...' : 'Clear it',
                      variant: AppButtonVariant.danger,
                      disabled: _busy,
                      onPressed: _clear,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
