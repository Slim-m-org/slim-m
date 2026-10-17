// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a reply also mentions the author it answers.
///
/// On unless the person turned it off, and the last choice sticks between
/// replies and restarts, as Discord's reply toggle does.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../providers/providers.dart';

const replyMentionKey = 'slimm.composer.reply_mention';

bool loadReplyMention(SharedPreferences prefs) =>
    prefs.getBool(replyMentionKey) ?? true;

class ReplyMentionController extends StateNotifier<bool> {
  ReplyMentionController(this._ref) : super(true) {
    _load();
  }

  final Ref _ref;
  var _answered = false;

  /// A flip made while this was still reading is the newer truth.
  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    if (!_answered) state = loadReplyMention(prefs);
  }

  Future<void> set(bool enabled) async {
    _answered = true;
    state = enabled;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(replyMentionKey, enabled);
  }
}

final replyMentionProvider =
    StateNotifierProvider<ReplyMentionController, bool>(
      ReplyMentionController.new,
    );
