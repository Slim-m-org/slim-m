// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last search made from each conversation's own search button, kept in
/// memory for the session, so stepping through hits one by one does not mean
/// typing the search again each time the palette reopens.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../accounts/providers/account_slot.dart' show accountActiveProvider;
import '../../messages/providers/message_search_query.dart';

/// A conversation's last search: its text and every chip, its own `in:` first.
typedef RememberedSearch = ({String text, List<SearchFilter> filters});

class ConversationSearchMemory {
  final _byConversation = <String, RememberedSearch>{};

  RememberedSearch? recall(String channelId) => _byConversation[channelId];

  /// Keeps [text] and [filters] for [scope]'s conversation while its chip is
  /// among them; with the chip gone, or nothing searched past it, forgets it.
  void remember(SearchFilter scope, String text, List<SearchFilter> filters) {
    final channelId = scope.channelId;
    if (channelId == null) return;
    final scoped = filters.any((f) => f.channelId == channelId);
    final searched = text.trim().isNotEmpty || filters.length > 1;
    if (scoped && searched) {
      _byConversation[channelId] = (text: text, filters: [...filters]);
    } else {
      _byConversation.remove(channelId);
    }
  }
}

/// Rebuilt empty whenever the account, server or active slot changes.
final conversationSearchMemoryProvider = Provider<ConversationSearchMemory>((
  ref,
) {
  ref
    ..watch(sessionProvider)
    ..watch(serverUrlProvider)
    ..watch(accountActiveProvider);
  return ConversationSearchMemory();
});
