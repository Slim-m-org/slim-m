// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which sections the palette shows for its query, in order. With chips, or
/// while a filter's value is being typed, it is a message search: the
/// suggestions, then the hits. Otherwise a leading `#` or `@` narrows it to
/// channels or people, and plain text searches everything.
library;

import 'package:slimm_design_system/design_system.dart';

import '../providers/palette_message_search.dart';
import 'command_palette_items.dart';
import 'command_palette_results.dart';

/// Every row the palette might show; [paletteSections] picks and orders them.
typedef PaletteSectionInputs = ({
  String query,
  bool filtering,
  bool typingValue,
  List<PaletteResultItem> suggestions,
  String suggestionsLabel,
  PaletteMessageSearch messages,
  List<PaletteResultItem> messageItems,
  List<(String, List<PaletteResultItem>)> channels,
  List<PaletteResultItem> people,
  List<PaletteResultItem> transcripts,
  List<PaletteResultItem> actions,
});

List<PaletteSection> paletteSections(PaletteSectionInputs i) {
  if (i.typingValue || i.filtering) {
    return [
      if (i.suggestions.isNotEmpty)
        (label: i.suggestionsLabel, items: i.suggestions, count: null),
      if (!i.typingValue && !i.messages.forbidden) _messages(i),
    ].where((s) => s.items.isNotEmpty).toList();
  }
  final scope = parsePaletteQuery(i.query).scope;
  final everything = scope == PaletteScope.all;
  return <PaletteSection>[
    if (everything || scope == PaletteScope.channels)
      for (final (label, items) in i.channels)
        (label: label, items: items, count: null),
    if (everything || scope == PaletteScope.people)
      (label: 'People', items: i.people, count: null),
    if (everything && !i.messages.forbidden) _messages(i),
    if (everything) (label: 'Transcripts', items: i.transcripts, count: null),
    if (everything) (label: 'Actions', items: i.actions, count: null),
  ].where((s) => s.items.isNotEmpty).toList();
}

/// The hits, ending in a row that fetches the next page while there may be one.
PaletteSection _messages(PaletteSectionInputs i) {
  final search = i.messages;
  return (
    label: 'Messages',
    count: i.filtering ? search.results.length : null,
    items: [
      ...i.messageItems,
      if (i.filtering && search.more)
        PaletteResultItem(
          label: search.loading ? 'Loading more' : 'Show more messages',
          leading: AppIcons.chevronDown,
          keepsOpen: true,
          onSelect: (_, _) => search.loadMore(),
        ),
    ],
  );
}

/// What a screen reader hears once a message search settles.
String paletteAnnouncement(
  PaletteMessageSearch messages,
  bool filtering,
  String query,
) {
  if (!filtering && query.isEmpty) return '';
  if (messages.loading) return 'Searching messages.';
  if (messages.failed) return 'Search failed.';
  final count = messages.results.length;
  if (count == 0) return filtering ? 'No matches.' : '';
  return '$count ${count == 1 ? 'message' : 'messages'} found.';
}
