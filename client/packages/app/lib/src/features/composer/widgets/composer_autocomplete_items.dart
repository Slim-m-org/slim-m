// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a trigger into a ranked list of things to insert.
///
/// Pure, and separate from the overlay that draws it, for the same reason
/// [autocompleteQueryAt] is separate from both: ranking is where "did it
/// offer the obvious thing first" lives, and that is a list-in, list-out
/// question rather than a widget one.
library;

import 'package:slimm_api/api.dart' as api;

import '../../modules/module_detail.dart';
import 'composer_autocomplete_query.dart';
import 'mention_match.dart';
import '../../emoji/widgets/emoji_catalog.dart';

/// Most rows to offer at once.
///
/// Short deliberately: the point of an inline autocomplete is that the right
/// answer is visible without reading, and a list long enough to scroll is a
/// picker, which this app already has behind the `+` button.
const int maxAutocompleteRows = 8;

/// One offer. [insert] is what replaces the trigger span, and it carries its
/// own trailing space where one is wanted, so the caller never has to know
/// which kinds want one.
class AutocompleteSuggestion {
  const AutocompleteSuggestion({
    required this.insert,
    required this.label,
    this.detail,
    this.glyph,
    this.imageEmoji,
    this.userId,
    this.isMassMention = false,
    this.isRoleMention = false,
    this.offline = false,
  });

  final String insert;

  /// What the row reads as, and what a screen reader says.
  final String label;

  /// A muted second column: an emoji's shortcode, a member's username.
  final String? detail;

  /// A literal character to draw at the leading edge, for a unicode emoji.
  final String? glyph;

  /// A deployment emoji to draw from its own image instead.
  final api.CustomEmoji? imageEmoji;

  /// A member, so the row can show their avatar rather than a generic glyph.
  final String? userId;

  /// `@everyone`/`@here` rather than a real member: the overlay (which is
  /// free to depend on Flutter, unlike this file) draws a members glyph
  /// instead of the plain command-row fallback. Kept as a flag rather than an
  /// `IconData` field so this file's own vocabulary of offers stays pure Dart.
  final bool isMassMention;

  /// A role (`@[Role Name]`) rather than a member or a mass mention: the
  /// overlay draws the same shield glyph `member_roles_sheet.dart` already
  /// uses for a role row, rather than the plain command-row fallback.
  final bool isRoleMention;

  /// A bot command whose bot has no live socket: drawn dim, with the reason.
  final bool offline;
}

/// The built-in slash commands: text substitution only, needing nothing from
/// the server. Module `slash-command` extension points are the other half,
/// merged in by [_commandRows] - those are not substituted but run on send
/// (see `slash_command.dart`).
const _commands = <(String, String, String)>[
  ('shrug', r'¯\_(ツ)_/¯', 'append a shrug'),
  ('tableflip', '(╯°□°)╯︵ ┻━┻', 'flip a table'),
  ('unflip', '┬─┬ ノ( ゜-゜ノ)', 'put it back'),
];

/// The offers for [query], ranked, capped at [maxAutocompleteRows].
///
/// [canMentionEveryone] gates the two reserved rows [_massMentions] adds:
/// offering `@everyone`/`@here` to somebody the server would not actually
/// wake anyone for (`push::recipients::resolved_mentions`) would be a row
/// that looks actionable and quietly is not, the same "no handler rather
/// than a button that would just 403" choice this client already makes
/// elsewhere. Defaults false so the emoji and command callers, which have no
/// opinion on it, need not pass anything.
List<AutocompleteSuggestion> autocompleteSuggestions({
  required AutocompleteQuery query,
  required List<api.CustomEmoji> custom,
  required List<api.UserProfile> members,
  String? selfId,
  bool canMentionEveryone = false,
  List<api.SlashCommand> slashCommands = const [],
  List<api.App> apps = const [],
  List<api.ChannelBotCommand> botCommands = const [],
  bool gifSearch = false,
}) => switch (query.kind) {
  AutocompleteKind.emoji => _emoji(query.term, custom),
  AutocompleteKind.mention => _mentions(
    query.term,
    members,
    selfId,
    canMentionEveryone: canMentionEveryone,
  ),
  AutocompleteKind.command => _commandRows(
    query.term,
    slashCommands,
    apps,
    botCommands,
    gifSearch: gifSearch,
  ),
  AutocompleteKind.botCommand => _botCommandRows(
    query.term,
    botCommands,
    prefix: query.prefix,
  ).take(maxAutocompleteRows).toList(growable: false),
  AutocompleteKind.botOption => _botOptionRows(query, botCommands),
};

/// The lowercased `prefix` + keyword of every bot command with a choice list.
Set<String> botChoiceTriggers(List<api.ChannelBotCommand> botCommands) => {
  for (final command in botCommands)
    if (command.options.any((o) => o.choices.isNotEmpty))
      '${command.prefix}${command.name}'.toLowerCase(),
};

/// [autocompleteQueryAt] with the bot prefixes and choice triggers of [botCommands].
AutocompleteQuery? composerQueryAt(
  String text,
  int caret,
  List<api.ChannelBotCommand> botCommands,
) => autocompleteQueryAt(
  text,
  caret,
  botPrefixes: botCommands.map((c) => c.prefix),
  botTriggers: botChoiceTriggers(botCommands),
);

/// The choices of the option under the caret, prefix matches first. Not
/// capped at [maxAutocompleteRows]: a pick list is the whole set, and the
/// overlay scrolls it.
List<AutocompleteSuggestion> _botOptionRows(
  AutocompleteQuery query,
  List<api.ChannelBotCommand> botCommands,
) {
  final options = [
    for (final c in botCommands)
      if ('${c.prefix}${c.name}'.toLowerCase() == query.command) ...c.options,
  ];
  if (query.argIndex >= options.length) return const [];
  final option = options[query.argIndex];
  final matching = option.choices.where(
    (c) => query.term.isEmpty || c.toLowerCase().contains(query.term),
  );
  final leading = matching.where((c) => c.toLowerCase().startsWith(query.term));
  final rest = matching.where((c) => !c.toLowerCase().startsWith(query.term));
  return [
    for (final choice in [...leading, ...rest])
      AutocompleteSuggestion(
        insert: '$choice ',
        label: choice,
        detail: option.name,
      ),
  ];
}

List<AutocompleteSuggestion> _emoji(
  String term,
  List<api.CustomEmoji> custom,
) => [
  for (final result in pickerResults(
    query: term,
    category: EmojiCategory.custom,
    recent: const [],
    custom: custom,
  ).take(maxAutocompleteRows))
    switch (result) {
      DeploymentEmoji(:final emoji) => AutocompleteSuggestion(
        // A shortcode is already delimited, so it needs no extra colons.
        insert: '${emoji.shortcode} ',
        label: emoji.shortcode,
        detail: 'this Space',
        imageEmoji: emoji,
      ),
      UnicodeEmoji(:final emoji) => AutocompleteSuggestion(
        insert: '${emoji.char} ',
        label: emoji.name,
        detail: ':${emoji.shortName}:',
        glyph: emoji.char,
      ),
    },
];

/// The two reserved mentions `push::recipients::resolved_mentions` treats
/// specially, offered ahead of any real member: they name the whole channel
/// rather than one person in it, which is the more consequential thing to
/// offer first when both would otherwise match equally on one typed letter.
const _massMentions = <(String name, String detail)>[
  ('everyone', 'Notify everyone who can see this channel'),
  ('here', 'Notify everyone currently online'),
];

/// Members whose username or display name contains [term], the roles any of
/// them holds whose name contains it, plus `@everyone`/`@here` when
/// [canMentionEveryone] allows offering them at all.
///
/// Yourself excluded from the member half: mentioning yourself notifies
/// nobody, and the row would sit where the person you meant to reach was
/// about to appear. Prefix matches lead, because that is what somebody
/// typing three letters means. Roles are offered unconditionally rather than
/// gated the way `_massMentions` is on [canMentionEveryone]: whether typing
/// one actually wakes anyone is a per-role `mentionable` flag this list has
/// no visibility into (see `Role.mentionable`), not a caller-wide permission
/// this function could check up front.
List<AutocompleteSuggestion> _mentions(
  String term,
  List<api.UserProfile> members,
  String? selfId, {
  required bool canMentionEveryone,
}) {
  return [
    if (canMentionEveryone) ..._massMentionRows(term),
    ..._roleSuggestions(term, members),
    for (final m in _memberCandidates(term, members, selfId))
      AutocompleteSuggestion(
        insert: '@${m.username} ',
        label: m.displayName,
        detail: '@${m.username}',
        userId: m.id,
      ),
  ].take(maxAutocompleteRows).toList(growable: false);
}

List<api.UserProfile> _memberCandidates(
  String term,
  List<api.UserProfile> members,
  String? selfId,
) {
  final ranked =
      <(int, api.UserProfile)>[
        for (final m in members)
          if (m.id != selfId)
            if (mentionRank(term, m) case final rank?) (rank, m),
      ]..sort((a, b) {
        if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
        final byName = foldForMatch(
          a.$2.displayName,
        ).compareTo(foldForMatch(b.$2.displayName));
        if (byName != 0) return byName;
        return a.$2.username.toLowerCase().compareTo(
          b.$2.username.toLowerCase(),
        );
      });
  final candidates = [for (final (_, m) in ranked) m];
  return candidates;
}

List<AutocompleteSuggestion> _massMentionRows(String term) => [
  for (final (name, detail) in _massMentions)
    if (term.isEmpty || name.startsWith(term))
      AutocompleteSuggestion(
        insert: '@$name ',
        label: '@$name',
        detail: detail,
        isMassMention: true,
      ),
];

/// The distinct role names [term] matches across [members]' own `roles`
/// field - the only role catalog available to an ordinary composer, since
/// `GET /roles` itself stays MANAGE_ROLES-gated. A role nobody currently in
/// the roster holds is therefore not offered here, the same boundary
/// `knownRoleNamesFrom` (`channel_screen.dart`) already draws for rendering.
/// Always inserted with the `@[Name]` bracket syntax, even for a name that
/// would also fit the plain `@name` charset, so the rule stays simple and
/// exceptionless: bracketed is always a role.
List<AutocompleteSuggestion> _roleSuggestions(
  String term,
  List<api.UserProfile> members,
) {
  final byName = <String, String>{}; // lower-cased name -> its own casing
  for (final member in members) {
    for (final name in member.roles) {
      byName.putIfAbsent(name.toLowerCase(), () => name);
    }
  }
  final matches =
      byName.values
          .where((name) => term.isEmpty || name.toLowerCase().contains(term))
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  return [
    for (final name in matches)
      AutocompleteSuggestion(
        insert: '@[$name] ',
        label: '@$name',
        detail: 'Role',
        isRoleMention: true,
      ),
  ];
}

/// Built-ins, then module slash commands, then apps, then bot commands. A
/// bot command inserts its own registered prefix and keyword (`!ping`, not
/// `/ping`) and is never run - see docs/decisions/0031.
List<AutocompleteSuggestion> _commandRows(
  String term,
  List<api.SlashCommand> slashCommands,
  List<api.App> apps,
  List<api.ChannelBotCommand> botCommands, {
  bool gifSearch = false,
}) => [
  if (gifSearch && (term.isEmpty || 'gif'.startsWith(term)))
    const AutocompleteSuggestion(
      insert: '/gif ',
      label: '/gif',
      detail: 'search for a GIF',
    ),
  ..._builtinRows(term),
  ..._slashCommandRows(term, slashCommands),
  ..._appRows(term, apps),
  ..._botCommandRows(term, botCommands),
].take(maxAutocompleteRows).toList(growable: false);

bool _startsWithTerm(String term, String name) =>
    term.isEmpty || name.toLowerCase().startsWith(term);

List<AutocompleteSuggestion> _builtinRows(String term) => [
  for (final (name, text, detail) in _commands)
    if (term.isEmpty || name.startsWith(term))
      AutocompleteSuggestion(insert: '$text ', label: '/$name', detail: detail),
];

List<AutocompleteSuggestion> _slashCommandRows(
  String term,
  List<api.SlashCommand> slashCommands,
) => [
  for (final command in slashCommands)
    if (_startsWithTerm(term, command.name))
      AutocompleteSuggestion(
        insert: '/${command.name} ',
        label: '/${command.name}',
        detail: moduleCommandDetail(command.description, command.module),
      ),
];

// An app launches on its keyword alone (no arguments), so its row inserts the complete `/module-id` ready to send.
List<AutocompleteSuggestion> _appRows(String term, List<api.App> apps) => [
  for (final app in apps)
    if (_startsWithTerm(term, app.moduleId))
      AutocompleteSuggestion(
        insert: '/${app.moduleId}',
        label: '/${app.moduleId}',
        detail: app.name,
      ),
];

/// One row per trigger; a registration from before clashes were refused can still repeat one.
List<AutocompleteSuggestion> _botCommandRows(
  String term,
  List<api.ChannelBotCommand> botCommands, {
  String? prefix,
}) {
  final triggers = <String>{};
  return [
    for (final command in botCommands)
      if ((prefix == null || command.prefix == prefix) &&
          _startsWithTerm(term, command.name) &&
          triggers.add('${command.prefix}${command.name.toLowerCase()}'))
        AutocompleteSuggestion(
          insert: '${command.prefix}${command.name} ',
          label: '${command.prefix}${command.name}',
          detail:
              '${command.description} · ${command.botDisplayName}'
              '${command.offline ? ' · offline' : ''}',
          offline: command.offline,
        ),
  ];
}
