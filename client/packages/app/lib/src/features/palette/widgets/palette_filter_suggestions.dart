// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the palette offers for the word being typed: the filter keys while
/// the word could still become one, then values for the key it names -
/// people for `from:`, channels for `in:`, kinds for `has:`, dates for the
/// date keys.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../messages/providers/message_search_query.dart';
import '../../messages/providers/message_search_request.dart';
import '../providers/palette_query.dart';
import 'command_palette_items.dart';

/// What picking a suggestion does: [complete] puts `key:` in the field,
/// [add] makes a chip of a finished filter.
typedef FilterSuggestionActions = ({
  ValueChanged<String> complete,
  ValueChanged<SearchFilter> add,
});

/// Where suggestions are drawn from.
typedef FilterSuggestionSources = ({
  List<api.UserProfile> members,
  List<Channel> channels,
  DateTime today,
});

const _keyHints = {
  SearchKey.from: 'a person',
  SearchKey.mentions: 'a person',
  SearchKey.inChannel: 'a channel',
  SearchKey.has: 'image, video, file, link, poll',
  SearchKey.pinned: 'true or false',
  SearchKey.before: 'a date',
  SearchKey.after: 'a date',
  SearchKey.during: 'a day, month or year',
  SearchKey.between: 'two dates',
};

const _kindHints = {
  'image': 'Images and GIFs',
  'video': 'Videos',
  'file': 'Other files',
  'link': 'Links',
  'voice': 'Voice messages',
  'poll': 'Polls',
  'embed': 'Bot embeds',
  'attachment': 'Any file',
};

/// The suggestions for [word]; keys only while [offerKeys], so a plain word
/// typed into the palette is never mistaken for one.
List<PaletteResultItem> filterSuggestions(
  String word, {
  required bool offerKeys,
  required FilterSuggestionSources sources,
  required FilterSuggestionActions actions,
}) {
  final colon = word.indexOf(':');
  final key = colon > 0 ? SearchKey.named(word.substring(0, colon)) : null;
  if (key != null) {
    return _values(key, word.substring(colon + 1), sources, actions);
  }
  if (!offerKeys || colon >= 0) return const [];
  final typed = word.toLowerCase();
  return [
    for (final key in SearchKey.values)
      if (key.word.startsWith(typed))
        PaletteResultItem(
          label: '${key.word}:',
          kind: PaletteKind.filter,
          leading: searchKeyIcon(key),
          hint: _keyHints[key],
          keepsOpen: true,
          onSelect: (_, _) async => actions.complete('${key.word}:'),
        ),
  ];
}

/// The suggestions for the word [field] is typing, picked straight into it.
/// Keys are offered while [filtering] only as a word is typed or with the field
/// empty: after a finished word the hits come first, so Enter opens one.
List<PaletteResultItem> fieldSuggestions(
  PaletteField field, {
  required bool filtering,
  required List<api.UserProfile> members,
  required List<Channel> channels,
}) => filterSuggestions(
  field.word,
  offerKeys: filtering && (field.word.isNotEmpty || field.text.trim().isEmpty),
  sources: (members: members, channels: channels, today: DateTime.now()),
  actions: (complete: field.completeKey, add: field.add),
);

/// What the suggestions for [word] are headed: what the key being typed takes.
String filterSuggestionsLabel(String word) {
  final colon = word.indexOf(':');
  final key = colon > 0 ? SearchKey.named(word.substring(0, colon)) : null;
  return switch (key) {
    null => 'Search options',
    SearchKey.from || SearchKey.mentions => 'People',
    SearchKey.inChannel => 'Channels',
    SearchKey.has => 'Content',
    SearchKey.pinned => 'Pinned',
    _ => 'Dates',
  };
}

/// The glyph a filter's key is drawn with, on a suggestion and on its chip.
IconData searchKeyIcon(SearchKey key) => switch (key) {
  SearchKey.from => AppIcons.account,
  SearchKey.mentions => AppIcons.mentions,
  SearchKey.inChannel => AppIcons.hash,
  SearchKey.has => AppIcons.attachFile,
  SearchKey.pinned => AppIcons.pin,
  SearchKey.before ||
  SearchKey.after ||
  SearchKey.during ||
  SearchKey.between => AppIcons.clock,
};

typedef _Option = ({SearchFilter filter, String label, String? hint});

List<PaletteResultItem> _values(
  SearchKey key,
  String typed,
  FilterSuggestionSources sources,
  FilterSuggestionActions actions,
) {
  final lower = typed.toLowerCase();
  final List<_Option> options = switch (key) {
    SearchKey.from || SearchKey.mentions => [
      for (final member in _people(sources.members, typed))
        (
          filter: SearchFilter(key, member.username, label: member.displayName),
          label: member.displayName,
          hint: '@${member.username}',
        ),
    ],
    SearchKey.inChannel => [
      for (final channel in _channels(sources.channels, typed))
        (
          filter: SearchFilter(
            key,
            channel.name,
            label: '#${channel.name}',
            channelId: channel.id,
          ),
          label: '#${channel.name}',
          hint: null,
        ),
    ],
    SearchKey.has => [
      for (final kind in searchHasKinds)
        if (kind.startsWith(lower))
          (
            filter: SearchFilter(key, kind),
            label: kind,
            hint: _kindHints[kind],
          ),
    ],
    SearchKey.pinned => [
      for (final (value, hint) in const [
        ('true', 'Pinned messages'),
        ('false', 'Messages not pinned'),
      ])
        if (value.startsWith(lower))
          (filter: SearchFilter(key, value), label: value, hint: hint),
    ],
    _ => [
      for (final (value, hint) in _dates(key, sources.today))
        if (value.startsWith(typed))
          (filter: SearchFilter(key, value), label: value, hint: hint),
    ],
  };
  final exact = canonicalSearchValue(key, typed);
  final listed = options.any((o) => o.filter.value == exact);
  final typedOption = exact == null || listed
      ? null
      : _item(key, (
          filter: SearchFilter(key, exact),
          label: exact,
          hint: null,
        ), actions);
  final shown = [
    for (final option in options.take(paletteResultLimit))
      _item(key, option, actions),
  ];
  // A typed name is offered only when nobody listed matches it; a typed date or kind leads.
  if (_namesSomeone.contains(key)) {
    return shown.isEmpty ? [?typedOption] : shown;
  }
  return [?typedOption, ...shown];
}

const _namesSomeone = {SearchKey.from, SearchKey.mentions, SearchKey.inChannel};

PaletteResultItem _item(
  SearchKey key,
  _Option option,
  FilterSuggestionActions actions,
) => PaletteResultItem(
  label: option.label,
  kind: PaletteKind.filter,
  leading: searchKeyIcon(key),
  hint: option.hint,
  keepsOpen: true,
  semanticLabel: '${key.word}: ${option.label}',
  onSelect: (_, _) async => actions.add(option.filter),
);

Iterable<api.UserProfile> _people(List<api.UserProfile> members, String typed) {
  final q = api.foldMarks(typed.startsWith('@') ? typed.substring(1) : typed);
  return members.where(
    (m) =>
        api.foldMarks(m.displayName).contains(q) ||
        m.username.toLowerCase().contains(q),
  );
}

Iterable<Channel> _channels(List<Channel> channels, String typed) {
  final q = api.foldMarks(typed.startsWith('#') ? typed.substring(1) : typed);
  return channels.where(
    (c) =>
        (c.kind == 'text' || c.kind == 'voice') &&
        api.foldMarks(c.name).contains(q),
  );
}

/// Quick picks for a date key, counted back from [today].
List<(String, String)> _dates(SearchKey key, DateTime today) {
  String ago(int days) =>
      searchDayText(DateTime(today.year, today.month, today.day - days));
  final day = DateTime(today.year, today.month, today.day);
  String month(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
  return switch (key) {
    SearchKey.during => [
      (ago(0), 'Today'),
      (ago(1), 'Yesterday'),
      (month(day), 'This month'),
      (month(DateTime(day.year, day.month - 1)), 'Last month'),
      ('${day.year}', 'This year'),
    ],
    SearchKey.between => [
      ('${ago(6)}..${ago(0)}', 'The last 7 days'),
      ('${ago(29)}..${ago(0)}', 'The last 30 days'),
    ],
    _ => [
      (ago(0), 'Today'),
      (ago(1), 'Yesterday'),
      (ago(7), 'A week ago'),
      (ago(30), 'A month ago'),
    ],
  };
}

/// A suggestion row: a key in code type (`from:`), or a value with its hint
/// at the row's end.
class PaletteFilterRowBody extends StatelessWidget {
  const PaletteFilterRowBody({super.key, required this.item});

  final PaletteResultItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final isKey = item.label.endsWith(':');
    final label = Text(
      item.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (isKey ? AppText.code : AppText.ui).copyWith(
        fontSize: AppText.ui.fontSize,
        color: tokens.textPrimary,
      ),
    );
    final hint = item.hint == null
        ? null
        : Text(
            item.hint!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          );
    // A key reads with its hint beside it; a value keeps its hint at the row's end.
    return Row(
      spacing: AppSpacing.s12,
      children: [
        Icon(item.leading, size: AppSizes.icon16, color: tokens.textSecondary),
        if (isKey) ...[
          label,
          if (hint != null) Flexible(child: hint),
        ] else ...[
          Expanded(flex: 3, child: label),
          if (hint != null) Flexible(flex: 2, child: hint),
        ],
      ],
    );
  }
}
