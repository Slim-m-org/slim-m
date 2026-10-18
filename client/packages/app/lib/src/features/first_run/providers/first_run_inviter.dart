// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the name an invite carries until the welcome step can show it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

/// Best effort: the welcome step reads fine without a name, so a failed check changes nothing.
Future<void> rememberInviter(
  SlimmApi api,
  StateController<String?> target,
  String? invite,
) async {
  if (invite == null) return;
  try {
    final check = await api.checkInvite(invite);
    if (check is InviteUsable) target.state = check.community.invitedBy;
  } on ApiException catch (error, stack) {
    reportFailure(LogTag.ui, 'look up who invited you', error, stack);
    return;
  }
}
