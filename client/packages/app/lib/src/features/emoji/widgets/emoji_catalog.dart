// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The emoji picker's data: which categories it shows, in what order, and
/// how a search query filters the catalog.
///
/// The `emojis` package (BSD-3, actively maintained, pure Dart, no Flutter
/// dependency) supplies every codepoint from its own bundled data. That data
/// lives inside the package's own source, never inside this repo, which is
/// what lets a picker exist at all under the hygiene gate that forbids an
/// emoji codepoint literal anywhere in `client/`.
///
/// The deployment's own emoji come from the server instead, and are images
/// rather than codepoints, so both kinds meet here as [PickerEmoji].
library;

import 'package:emojis/emoji.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_design_system/design_system.dart';

/// One picker tab. Two of these have no catalog [EmojiGroup] behind them:
/// [custom] shows what the deployment has uploaded and [recent] shows the
/// caller's own history, and each is absent entirely when it is empty.
///
/// [EmojiGroup.component] (skin tone and hair style modifiers, which compose
/// onto a base emoji rather than standing in as a reaction on their own) has
/// deliberately no tab here.
enum EmojiCategory {
  custom,
  recent,
  smileysEmotion,
  peopleBody,
  animalsNature,
  foodDrink,
  activities,
  travelPlaces,
  objects,
  symbols,
  flags,
}

/// The real categories, in picker order. Excludes [EmojiCategory.custom] and
/// [EmojiCategory.recent], which the panel only shows once there is something
/// in them to show.
const List<EmojiCategory> emojiCategoriesInOrder = [
  EmojiCategory.smileysEmotion,
  EmojiCategory.peopleBody,
  EmojiCategory.animalsNature,
  EmojiCategory.foodDrink,
  EmojiCategory.activities,
  EmojiCategory.travelPlaces,
  EmojiCategory.objects,
  EmojiCategory.symbols,
  EmojiCategory.flags,
];

extension EmojiCategoryInfo on EmojiCategory {
  String get label => switch (this) {
    EmojiCategory.custom => 'Space emoji',
    EmojiCategory.recent => 'Recently used',
    EmojiCategory.smileysEmotion => 'Smileys and emotion',
    EmojiCategory.peopleBody => 'People',
    EmojiCategory.animalsNature => 'Animals and nature',
    EmojiCategory.foodDrink => 'Food and drink',
    EmojiCategory.activities => 'Activities',
    EmojiCategory.travelPlaces => 'Travel and places',
    EmojiCategory.objects => 'Objects',
    EmojiCategory.symbols => 'Symbols',
    EmojiCategory.flags => 'Flags',
  };

  IconData get icon => switch (this) {
    EmojiCategory.custom => AppIcons.customEmoji,
    EmojiCategory.recent => AppIcons.clock,
    EmojiCategory.smileysEmotion => AppIcons.smile,
    EmojiCategory.peopleBody => AppIcons.peopleBody,
    EmojiCategory.animalsNature => AppIcons.animalsNature,
    EmojiCategory.foodDrink => AppIcons.foodDrink,
    EmojiCategory.activities => AppIcons.activities,
    EmojiCategory.travelPlaces => AppIcons.travelPlaces,
    EmojiCategory.objects => AppIcons.objects,
    EmojiCategory.symbols => AppIcons.symbols,
    EmojiCategory.flags => AppIcons.flags,
  };

  /// The catalog group this tab draws from, or null for [custom] and
  /// [recent], neither of which is a catalog group.
  EmojiGroup? get group => switch (this) {
    EmojiCategory.custom => null,
    EmojiCategory.recent => null,
    EmojiCategory.smileysEmotion => EmojiGroup.smileysEmotion,
    EmojiCategory.peopleBody => EmojiGroup.peopleBody,
    EmojiCategory.animalsNature => EmojiGroup.animalsNature,
    EmojiCategory.foodDrink => EmojiGroup.foodDrink,
    EmojiCategory.activities => EmojiGroup.activities,
    EmojiCategory.travelPlaces => EmojiGroup.travelPlaces,
    EmojiCategory.objects => EmojiGroup.objects,
    EmojiCategory.symbols => EmojiGroup.symbols,
    EmojiCategory.flags => EmojiGroup.flags,
  };

  /// The browse view's own section header text - "Frequently used" for
  /// [recent], Discord's own wording for that section, while [label] (the
  /// rail's tooltip and the live-region announcement) keeps "Recently used"
  /// everywhere else so neither of those changes meaning.
  String get sectionLabel =>
      this == EmojiCategory.recent ? 'Frequently used' : label;
}

/// One tile in the picker, whichever kind it is.
///
/// [token] is the single value a pick produces: it is what the composer
/// inserts and what a reaction is keyed by, so those two cannot disagree
/// about what was chosen.
sealed class PickerEmoji {
  const PickerEmoji();

  String get token;

  /// The accessible name, and what a search query matches against.
  String get label;

  /// The preview footer's own name line - distinct from [label], which for
  /// [DeploymentEmoji] is already the shortcode.
  String get displayName;

  /// The preview footer's `:name:` line.
  String get shortcode;
}

/// A codepoint from the bundled catalog.
final class UnicodeEmoji extends PickerEmoji {
  const UnicodeEmoji(this.emoji);

  final Emoji emoji;

  @override
  String get token => emoji.char;

  @override
  String get label => emoji.name;

  @override
  String get displayName => emoji.name;

  @override
  String get shortcode => ':${emoji.shortName}:';
}

/// One of the deployment's own, drawn from its image and typed between
/// colons. The delimiters come from [CustomEmoji.shortcode] rather than being
/// spelled again here.
final class DeploymentEmoji extends PickerEmoji {
  const DeploymentEmoji(this.emoji);

  final CustomEmoji emoji;

  @override
  String get token => emoji.shortcode;

  @override
  String get label => emoji.shortcode;

  @override
  String get displayName => emoji.name;

  @override
  String get shortcode => emoji.shortcode;
}

/// The tabs to offer. [EmojiCategory.custom] leads when the deployment has
/// any, so its own emoji are the first thing the picker offers.
List<EmojiCategory> pickerTabs({
  required bool hasCustom,
  required bool hasRecent,
}) => [
  if (hasCustom) EmojiCategory.custom,
  if (hasRecent) EmojiCategory.recent,
  ...emojiCategoriesInOrder,
];

/// Which tab is actually shown, given the one the user picked (null until
/// they pick one) and whether there are custom emoji to show.
///
/// A deployment with none opens on smileys exactly as it always has, and a
/// selected custom tab falls back there if the last emoji is deleted while
/// the picker is open.
EmojiCategory effectiveCategory(
  EmojiCategory? chosen, {
  required bool hasCustom,
}) {
  if (chosen == null) {
    return hasCustom ? EmojiCategory.custom : EmojiCategory.smileysEmotion;
  }
  if (chosen == EmojiCategory.custom && !hasCustom) {
    return EmojiCategory.smileysEmotion;
  }
  return chosen;
}

/// The full catalog once, with [EmojiGroup.component] dropped. A top-level
/// `final` initializes lazily on first read and stays cached after, so this
/// is computed once per app run rather than once per keystroke.
final List<Emoji> _catalog = Emoji.all()
    .where((emoji) => emoji.emojiGroup != EmojiGroup.component)
    .toList(growable: false);

/// The tiles to show, for a query and a tab. A non-empty query searches
/// everything and ignores the tab, with the deployment's own matches first.
List<PickerEmoji> pickerResults({
  required String query,
  required EmojiCategory category,
  required List<String> recent,
  required List<CustomEmoji> custom,
}) {
  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) return [..._searchCustom(q, custom), ..._searchUnicode(q)];
  return switch (category) {
    EmojiCategory.custom => [for (final e in custom) DeploymentEmoji(e)],
    EmojiCategory.recent => recentEmojiEntries(recent, custom),
    _ => [
      for (final e in _catalog)
        if (e.emojiGroup == category.group) UnicodeEmoji(e),
    ],
  };
}

/// Substring match over name, short name, and keywords.
List<PickerEmoji> _searchUnicode(String q) => [
  for (final emoji in _catalog)
    if (emoji.name.contains(q) ||
        emoji.shortName.contains(q) ||
        emoji.keywords.any((keyword) => keyword.contains(q)))
      UnicodeEmoji(emoji),
];

/// Whether a custom emoji named [name] belongs in a list filtered by
/// [query]: a case-insensitive substring match with any typed colons
/// stripped, so `:parrot:` and `Parrot` find the same thing. An empty query
/// matches everything.
bool emojiNameMatches(String name, String query) {
  final needle = query.replaceAll(':', '').trim().toLowerCase();
  return needle.isEmpty || name.contains(needle);
}

/// The picker's own search: nothing for an empty needle, since the picker
/// shows no custom matches until something is typed.
List<PickerEmoji> _searchCustom(String q, List<CustomEmoji> custom) {
  if (q.replaceAll(':', '').isEmpty) return const [];
  return [
    for (final emoji in custom)
      if (emojiNameMatches(emoji.name, q)) DeploymentEmoji(emoji),
  ];
}

/// Resolves a recently-used shelf (the tokens persisted by
/// `recentEmojiProvider`) back to tiles, dropping any token nothing answers
/// to any more rather than showing a blank one for it. That covers both an
/// unknown codepoint and a custom emoji since deleted.
List<PickerEmoji> recentEmojiEntries(
  List<String> tokens,
  List<CustomEmoji> custom,
) => [
  for (final token in tokens)
    if (_resolveRecent(token, custom) case final entry?) entry,
];

PickerEmoji? _resolveRecent(String token, List<CustomEmoji> custom) {
  if (Emoji.byChar(token) case final emoji?) return UnicodeEmoji(emoji);
  for (final emoji in custom) {
    if (emoji.shortcode == token) return DeploymentEmoji(emoji);
  }
  return null;
}

/// One labeled group of tiles in the browse view: a category plus the
/// entries [pickerResults] already found for it, so a caller wiring up the
/// whole continuous scrollable does not call that once per tab itself.
final class EmojiSection {
  const EmojiSection({required this.category, required this.emoji});

  final EmojiCategory category;
  final List<PickerEmoji> emoji;
}

/// The browse view's own data: every [pickerTabs] entry, each with its
/// [pickerResults] folded in, empty ones dropped. A continuous scrollable
/// renders these one after another rather than swapping a single grid's
/// contents on a tab tap.
List<EmojiSection> pickerSections({
  required List<String> recent,
  required List<CustomEmoji> custom,
}) => [
  for (final category in pickerTabs(
    hasCustom: custom.isNotEmpty,
    hasRecent: recent.isNotEmpty,
  ))
    EmojiSection(
      category: category,
      emoji: pickerResults(
        query: '',
        category: category,
        recent: recent,
        custom: custom,
      ),
    ),
].where((section) => section.emoji.isNotEmpty).toList();
