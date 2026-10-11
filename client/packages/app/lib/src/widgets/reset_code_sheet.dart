// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The administrator's half of account recovery: issuing a one-time reset
/// code for somebody who cannot sign in (`POST
/// /admin/users/{userId}/reset-code`, `SlimmApi.issueResetCode`).
///
/// This deployment has no email, by decision: recovery is a code an admin
/// hands over out of band. Both ends of that decision existed on the wire
/// long before either had a surface, so an admin willing to help had no
/// button to press and the person locked out had no way back. This is the
/// issuing end; `screens/reset_password_sheet.dart` is the spending end.
///
/// The code is shown once and never again. The server keeps only its hash,
/// so there is nothing to re-read: closing this sheet without copying means
/// issuing a new one. That is why the code sits behind the administrator's own
/// password rather than being fetched when the menu opens - opening a menu by
/// accident should not burn a code, and a stolen session should not mint one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../format.dart';
import '../providers/display_preferences.dart';
import '../providers/providers.dart';
import '../providers/toasts.dart';
import 'reauth_sheet.dart';

/// Asks for the administrator's password, then shows the issued code for
/// [subjectId], named [subjectName] in its title.
Future<void> showResetCodeSheet(
  BuildContext context, {
  required String subjectId,
  required String subjectName,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  api.ResetCodeIssued? issued;
  final proved = await showReauthSheet(
    context,
    title: 'Password reset code for $subjectName',
    description:
        'Hand the code to them yourself, in person or however you already '
        'talk. Anyone holding it can set a new password on this account once.',
    submitLabel: 'Generate code',
    onSubmit: (password, _) async {
      try {
        issued = await container
            .read(apiProvider)
            .issueResetCode(subjectId, password: password);
        return null;
      } on api.ApiException catch (e) {
        return reauthFailure(e);
      }
    },
  );
  final code = issued;
  if (proved != true || code == null || !context.mounted) return;
  await showAppSheet<void>(
    context,
    builder: (context) =>
        _ResetCodeSheet(subjectName: subjectName, issued: code),
  );
}

/// The Moderate sub-view's own row for [showResetCodeSheet], a widget so
/// `member_moderate_view.dart`'s own row list stays one line per entry
/// instead of carrying this `onTap` inline.
class ResetCodeMenuItem extends StatelessWidget {
  const ResetCodeMenuItem({
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
    label: 'Password reset code...',
    leading: AppIcons.resetCode,
    submenu: true,
    onTap: () {
      onDone();
      unawaited(
        showResetCodeSheet(
          host,
          subjectId: subjectId,
          subjectName: subjectName,
        ),
      );
    },
  );
}

class _ResetCodeSheet extends ConsumerWidget {
  const _ResetCodeSheet({required this.subjectName, required this.issued});

  final String subjectName;
  final api.ResetCodeIssued issued;

  void _copy(WidgetRef ref) {
    Clipboard.setData(ClipboardData(text: issued.code));
    ref
        .read(toastsProvider.notifier)
        .show('Reset code copied.', severity: AppToastSeverity.success);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Padding(
      // The sheet supplies the top inset at every width; adding one here doubled it.
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
              'Password reset code for $subjectName',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'Shown once. Copy it now - it cannot be read again, and '
              'closing this means issuing a new one.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            _CodeBlock(code: issued.code),
            const SizedBox(height: AppSpacing.s8),
            Text(
              'Usable until ${formatDateTime(issued.expiresAt, use24Hour: watchUse24Hour(ref, context))}. '
              'Spending it signs them out everywhere.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: 'Done',
                    variant: AppButtonVariant.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: AppButton(
                    label: 'Copy code',
                    variant: AppButtonVariant.primary,
                    onPressed: () => _copy(ref),
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

/// The code itself, selectable so it can be read off or copied by hand on a
/// surface where the button is awkward.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s12,
      ),
      child: SelectableText(
        code,
        style: AppText.code.copyWith(color: tokens.textPrimary),
      ),
    );
  }
}
