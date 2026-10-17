// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Spending an invite code for the role it grants, after sign-in.
library;

import 'package:slimm_api/api.dart';

/// The session is real either way; a spent code should not strand someone on
/// the sign-in screen with no way forward.
Future<void> redeemInviteQuietly(SlimmApi api, String invite) async {
  try {
    await api.redeemInvite(invite);
  } on ApiException {
    return;
  }
}
