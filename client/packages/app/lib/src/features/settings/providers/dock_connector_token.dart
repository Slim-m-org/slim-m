// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A connector's token as the answer that minted it gave it, until the admin dismisses it.
/// It lives outside the Dock page so a token minted while the admin left is still shown on return.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';

/// Forgotten when the account signs out or changes, as the token belongs to that session.
final dockConnectorTokenProvider = StateProvider.family<String?, String>((
  ref,
  moduleId,
) {
  ref.watch(sessionProvider.select((session) => session.tokens?.userId));
  return null;
});
