// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The password a token that holds ADMINISTRATOR asks for, since that token
/// outlives every session and password change.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../permissions.dart';
import '../../auth/widgets/reauth_sheet.dart';

/// Whether a token holding [permissions] needs its issuer's password.
bool holdsAdministrator(int? permissions) =>
    (permissions ?? 0).hasPermission(Perm.administrator);

bool _asksForPassword(api.ApiException e) =>
    e is api.BadRequestException &&
    e.message.toLowerCase().contains('password is required');

/// Runs [run], asking for the password first when [needed].
///
/// A request that was not expected to need it but is refused for the lack of
/// one (a shared role may hold ADMINISTRATOR too) asks and retries. False when
/// the sheet was dismissed; any other failure throws for the caller to show.
Future<bool> runWithAdminPassword(
  BuildContext context, {
  required bool needed,
  required String title,
  required String description,
  required String submitLabel,
  required String whatFailed,
  required Future<void> Function(String? password) run,
}) async {
  if (!needed) {
    try {
      await run(null);
      return true;
    } on api.ApiException catch (e) {
      if (!_asksForPassword(e)) rethrow;
    }
  }
  if (!context.mounted) return false;
  final done = await showReauthSheet(
    context,
    title: title,
    description: description,
    submitLabel: submitLabel,
    onSubmit: (password, _) async {
      try {
        await run(password);
        return null;
      } on api.ApiException catch (e, stack) {
        api.reportFailure(api.LogTag.ui, whatFailed, e, stack);
        return reauthFailure(e, whatFailed);
      }
    },
  );
  return done == true;
}
