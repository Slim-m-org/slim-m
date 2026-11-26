// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Builds the palette's sections from the typed text, the stored channels and
/// members, and the message and transcript hits.
library;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:slimm_api/api.dart' as api;

import '../providers/palette_message_search.dart';
import '../providers/palette_query.dart';
import 'command_palette_items.dart';
import 'command_palette_results.dart';
import 'command_palette_sections.dart';
import 'palette_filter_suggestions.dart';
import 'palette_transcript_items.dart';

/// What [buildPaletteSections] reads from the palette's state.
typedef PaletteBuildInputs = ({
  PaletteResultInputs inputs,
  String query,
  PaletteField field,
  bool fullResults,
  PaletteMessageSearch messages,
  List<api.TranscriptHit> transcriptHits,
  String? currentChannelId,
  Map<String, String> mentionNames,
  Set<String> around,
  VoidCallback showFullResults,
  void Function(String prefix) scopeTo,
});

List<PaletteSection> buildPaletteSections(PaletteBuildInputs b) {
  final inputs = b.inputs;
  final channelsById = {for (final c in inputs.channels) c.id: c};
  final parsed = parsePaletteQuery(b.query);
  final query = parsed.text;
  final everything = parsed.scope == PaletteScope.all;
  final filtering = b.field.filters.isNotEmpty;
  return paletteSections((
    query: b.query,
    filtering: filtering || b.fullResults,
    typingValue: b.field.typingValue,
    suggestions: b.fullResults
        ? const []
        : fieldSuggestions(
            b.field,
            filtering: filtering,
            members: inputs.members,
            channels: inputs.channels,
          ),
    seeAll: b.messages.results.isEmpty
        ? null
        : seeAllResultsItem(query, b.showFullResults),
    suggestionsLabel: filterSuggestionsLabel(b.field.word),
    messages: b.messages,
    messageItems: buildMessageItems(
      b.messages.results,
      currentChannelId: b.currentChannelId,
      channelsById: channelsById,
      mentionNames: b.mentionNames,
    ),
    channels: channelSections(
      inputs.channels,
      query,
      selfDisplayName: inputs.me?.displayName,
      categoryNames: inputs.categoryNames,
      currentChannelId: b.currentChannelId,
      showAll: everything ? () => b.scopeTo('#') : null,
    ),
    people: buildMemberItems(
      inputs.members,
      query,
      inputs.me?.id,
      around: b.around,
      limit: everything ? paletteResultLimit : palettePeopleScopeLimit,
      showAll: everything ? () => b.scopeTo('@') : null,
    ),
    transcripts: buildTranscriptItems(
      b.transcriptHits,
      channelsById: channelsById,
    ),
    actions: buildActionItems(query, inputs.permissions),
  ));
}
