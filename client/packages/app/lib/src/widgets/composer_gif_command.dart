// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `/gif`: open the GIF picker from the keyboard, its search already focused.
library;

import 'package:flutter/foundation.dart';

/// The search a `/gif` message asks for (empty for a bare `/gif`), or null
/// when the text is anything else.
String? gifCommandQuery(String text) {
  final match = RegExp(
    r'^/gif(?:\s+(.*))?$',
    dotAll: true,
  ).firstMatch(text.trim());
  return match == null ? null : (match.group(1) ?? '').trim();
}

/// Lets the composer open its anchored picker panel on the GIF tab.
class ComposerPickerController extends ChangeNotifier {
  String? _gifQuery;

  void openGif(String query) {
    _gifQuery = query;
    notifyListeners();
  }

  /// The pending request, cleared as it is read so it opens the panel once.
  String? takeGifQuery() {
    final query = _gifQuery;
    _gifQuery = null;
    return query;
  }
}
