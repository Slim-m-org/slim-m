// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The question every sign-out asks first: it wipes that account's local
/// store, and with it any send that never left.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import '../../../widgets/confirm_dialog.dart';
import '../providers/account_services.dart' show ProviderReader;

/// Whether to go ahead: true at once with nothing unsent in the store [read]
/// reaches, otherwise what the person answers when told how many would go.
Future<bool> confirmSignOutLosingUnsent(
  BuildContext context,
  ProviderReader read,
) async {
  final unsent = await _unsentCount(read);
  if (unsent == 0) return true;
  if (!context.mounted) return false;
  return confirmDangerousAction(
    context,
    title: 'Sign out?',
    message: unsent == 1
        ? '1 message has not been sent yet. Signing out deletes it.'
        : '$unsent messages have not been sent yet. Signing out deletes them.',
    confirmLabel: 'Sign out',
  );
}

Future<int> _unsentCount(ProviderReader read) async {
  try {
    return await (await read(storeProvider.future)).unsentCount();
  } on Object catch (error, stack) {
    api.reportFailure(api.LogTag.data, 'count unsent messages', error, stack);
    return 0;
  }
}
