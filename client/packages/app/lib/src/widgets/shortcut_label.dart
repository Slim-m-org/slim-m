// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A control's tooltip with the key that does the same thing.
library;

import 'package:slimm_platform/platform.dart';

/// `' (Ctrl+Shift+S)'`, or empty on mobile/touch or once unbound - a hint naming a shortcut that cannot fire here would be worse than none.
String shortcutSuffix(AppAction action) {
  if (!isDesktopHost) return '';
  final keys = describeAppAction(action);
  return keys.isEmpty ? '' : ' (${keys.join('+')})';
}

String labelWithShortcut(String label, AppAction action) =>
    '$label${shortcutSuffix(action)}';
