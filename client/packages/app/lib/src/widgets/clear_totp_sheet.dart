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
/// So the sheet's job is to say what the act costs before it happens: it signs
/// the account out everywhere and is written to the moderation audit log, where
/// it names the administrator who did it. That is the trade the decision record
/// makes deliberately - the door exists, and it is not a quiet one. The
/// administrator's own password is the proof, so a stolen session cannot do it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import '../providers/toasts.dart';
import 'reauth_sheet.dart';

/// Opens the sheet for [subjectId], named [subjectName] in its title.
Future<void> showClearTotpSheet(
  BuildContext context, {
  required String subjectId,
  required String subjectName,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final cleared = await showReauthSheet(
    context,
    title: 'Clear two-factor for $subjectName?',
    description:
        'Signs them out everywhere, is logged, and leaves only their password.',
    submitLabel: 'Clear two-factor',
    dangerous: true,
    onSubmit: (password, _) async {
      try {
        await container
            .read(apiProvider)
            .clearMemberTotp(subjectId, password: password);
        return null;
      } on ApiException catch (e) {
        return reauthFailure(e);
      }
    },
  );
  if (cleared != true) return;
  container
      .read(toastsProvider.notifier)
      .show(
        'Two-factor cleared for $subjectName.',
        severity: AppToastSeverity.success,
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
