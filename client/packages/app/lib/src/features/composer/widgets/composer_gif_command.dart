// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `/gif`: open the GIF picker from the keyboard, its search already focused.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' show Attachment;
import 'package:slimm_design_system/design_system.dart' show kCompactWidth;

import 'composer_picker_panel.dart'
    show ComposerPickerTab, showComposerPickerSheet;

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

  /// `/gif`: the picker's GIF tab, searching for [query], with its field
  /// focused. A sheet on a compact window, the anchored panel otherwise.
  void openGifSearch(
    BuildContext context,
    String query, {
    required void Function(String) onSelectEmoji,
    required Future<void> Function(Attachment) onPickedGif,
  }) {
    if (MediaQuery.sizeOf(context).width < kCompactWidth) {
      unawaited(
        showComposerPickerSheet(
          context,
          onSelectEmoji: onSelectEmoji,
          onPickedGif: onPickedGif,
          initialTab: ComposerPickerTab.gif,
          gifQuery: query,
        ),
      );
    } else {
      openGif(query);
    }
  }

  /// The pending request, cleared as it is read so it opens the panel once.
  String? takeGifQuery() {
    final query = _gifQuery;
    _gifQuery = null;
    return query;
  }
}
