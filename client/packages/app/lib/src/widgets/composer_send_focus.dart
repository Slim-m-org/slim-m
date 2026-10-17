// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the composer typeable after a send from its button under a web
/// screen reader.
///
/// Activating the button moves browser focus onto it, which detaches the
/// field's browser text input while Flutter still has the field focused, so
/// nothing reopens it and every keystroke after the first send is lost.
/// Cycling the field's focus makes Flutter open a fresh input connection.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

void reattachFieldAfterButtonSend(
  BuildContext context,
  FocusNode field, {
  bool web = kIsWeb,
}) {
  if (!web || !MediaQuery.accessibleNavigationOf(context)) {
    field.requestFocus();
    return;
  }
  field.unfocus();
  WidgetsBinding.instance.addPostFrameCallback((_) => field.requestFocus());
}
