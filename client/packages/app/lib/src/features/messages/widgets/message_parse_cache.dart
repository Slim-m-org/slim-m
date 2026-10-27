// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Parse results kept per message text, so a rebuild reads the tree it already has.
library;

import 'message_inline.dart';
import 'message_fences.dart';
import 'message_markdown_blocks.dart';

/// Room for a 200-message window at about four text runs a message, with headroom.
///
/// An LRU smaller than the set being scrolled over gets no hits at all, and an entry is a short string plus its tree.
const kParseCacheCapacity = 2048;

/// A bounded least-recently-used map from text to its parsed value.
///
/// Keyed on the text itself: the parsers are pure, so an edit (new content)
/// misses by construction and a message id or revision adds nothing to the key.
class ParseCache<T> {
  ParseCache(this._parse, {this.capacity = kParseCacheCapacity});

  final T Function(String text) _parse;
  final int capacity;
  final _entries = <String, T>{};

  int get length => _entries.length;

  T of(String text) {
    final hit = _entries.remove(text);
    final value = hit ?? _parse(text);
    _entries[text] = value;
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
    return value;
  }
}

final _blocks = ParseCache<List<MessageBlock>>(splitMessageBlocks);
final _markdown = ParseCache<List<MarkdownBlock>>(splitMarkdownBlocks);
final _inline = ParseCache<List<InlineNode>>(parseInline);

/// Cached [splitMessageBlocks]; the returned list is shared, never mutate it.
List<MessageBlock> cachedMessageBlocks(String content) => _blocks.of(content);

/// Cached [splitMarkdownBlocks]; the returned list is shared, never mutate it.
List<MarkdownBlock> cachedMarkdownBlocks(String text) => _markdown.of(text);

/// Cached [parseInline]; the returned list is shared, never mutate it.
List<InlineNode> cachedInline(String text) => _inline.of(text);
