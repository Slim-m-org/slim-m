// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ranking, which is the half that decides whether Enter takes the row you
/// meant. The detector's own cases are in
/// `composer_autocomplete_query_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_items.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_query.dart';

api.UserProfile _member(String id, String username, [String? display]) =>
    api.UserProfile(
      id: id,
      username: username,
      displayName: display ?? username,
      createdAt: 0,
    );

const _members = [
  _Fixed('u-priya', 'priya'),
  _Fixed('u-kess', 'kess'),
  _Fixed('u-dorian', 'dorian'),
  _Fixed('u-apriya', 'apriya'),
];

/// A tiny record so the fixture list can be `const`.
class _Fixed {
  const _Fixed(this.id, this.username);
  final String id;
  final String username;
}

List<api.UserProfile> get members => [
  for (final m in _members) _member(m.id, m.username),
];

AutocompleteQuery _q(AutocompleteKind kind, String term) =>
    AutocompleteQuery(kind: kind, term: term, start: 0, end: term.length + 1);

List<AutocompleteSuggestion> _for(
  AutocompleteKind kind,
  String term, {
  String? selfId,
  List<api.CustomEmoji> custom = const [],
  bool canMentionEveryone = false,
  List<api.ChannelBotCommand> botCommands = const [],
}) => autocompleteSuggestions(
  query: _q(kind, term),
  custom: custom,
  members: members,
  selfId: selfId,
  canMentionEveryone: canMentionEveryone,
  botCommands: botCommands,
);

api.ChannelBotCommand _botCommand(
  String botId,
  String botName,
  String prefix,
  String name,
) => api.ChannelBotCommand(
  botUserId: botId,
  botUsername: botName,
  botDisplayName: botName,
  prefix: prefix,
  name: name,
  description: 'does $name things',
);

void main() {
  group('mentions', () {
    test('a prefix match leads a mere substring match', () {
      final rows = _for(AutocompleteKind.mention, 'priya');
      expect(rows.first.detail, '@priya');
      expect(
        rows.map((r) => r.detail),
        containsAll(['@priya', '@apriya']),
        reason: 'apriya still matches, it just does not lead',
      );
    });

    test('yourself is never offered', () {
      final rows = _for(AutocompleteKind.mention, '', selfId: 'u-kess');
      expect(
        rows.map((r) => r.detail),
        isNot(contains('@kess')),
        reason: 'mentioning yourself notifies nobody and takes a row',
      );
    });

    test('an empty term offers everyone, so @ alone is useful', () {
      expect(_for(AutocompleteKind.mention, '').length, members.length);
    });

    test(
      'inserts the username with a trailing space, not the display name',
      () {
        final row = _for(AutocompleteKind.mention, 'dor').first;
        expect(row.insert, '@dorian ');
      },
    );

    test('matches display name as well as username', () {
      final rows = autocompleteSuggestions(
        query: _q(AutocompleteKind.mention, 'nick'),
        custom: const [],
        members: [_member('u-1', 'npc', 'nick')],
      );
      expect(rows, hasLength(1));
    });

    test('carries the id, so the row can show a real avatar', () {
      expect(_for(AutocompleteKind.mention, 'dor').first.userId, 'u-dorian');
    });
  });

  group('mass mentions', () {
    test('absent when the caller was not granted MENTION_EVERYONE', () {
      final rows = _for(AutocompleteKind.mention, '');
      expect(
        rows.map((r) => r.label),
        isNot(anyOf(contains('@everyone'), contains('@here'))),
      );
    });

    test('both offered ahead of real members once granted', () {
      final rows = _for(AutocompleteKind.mention, '', canMentionEveryone: true);
      expect(rows.take(2).map((r) => r.label), ['@everyone', '@here']);
      expect(rows.map((r) => r.isMassMention).take(2), [true, true]);
    });

    test('a prefix narrows to the one reserved word it matches', () {
      final rows = _for(
        AutocompleteKind.mention,
        'eve',
        canMentionEveryone: true,
      );
      expect(rows.map((r) => r.label), ['@everyone']);
    });

    test('inserts with a trailing space, matching an ordinary mention', () {
      final row = _for(
        AutocompleteKind.mention,
        'here',
        canMentionEveryone: true,
      ).first;
      expect(row.insert, '@here ');
    });

    test('a real member is never flagged as a mass mention', () {
      final rows = _for(
        AutocompleteKind.mention,
        'dor',
        canMentionEveryone: true,
      );
      expect(rows.every((r) => !r.isMassMention), isTrue);
    });
  });

  group('emoji', () {
    test('a real shortcode search returns something insertable', () {
      final rows = _for(AutocompleteKind.emoji, 'smile');
      expect(rows, isNotEmpty);
      expect(rows.first.insert, isNotEmpty);
      expect(
        rows.first.insert.endsWith(' '),
        isTrue,
        reason:
            'the trailing space is part of the insert, so no caller has to '
            'know which kinds want one',
      );
    });

    test('is capped, so the list never becomes a scrolling picker', () {
      // A term matching a great many entries.
      expect(
        _for(AutocompleteKind.emoji, 'e').length,
        lessThanOrEqualTo(maxAutocompleteRows),
      );
    });
  });

  group('commands', () {
    test('a bare slash offers the whole set', () {
      final rows = _for(AutocompleteKind.command, '');
      expect(rows.map((r) => r.label), contains('/shrug'));
      expect(rows.length, greaterThan(1));
    });

    test('filters by prefix', () {
      final rows = _for(AutocompleteKind.command, 'shr');
      expect(rows, hasLength(1));
      expect(rows.first.label, '/shrug');
    });

    test('inserts the text, not the command name', () {
      final row = _for(AutocompleteKind.command, 'shrug').first;
      expect(row.insert, isNot(contains('shrug')));
      expect(row.insert.trim(), isNotEmpty);
    });

    test('an unknown command offers nothing rather than everything', () {
      expect(_for(AutocompleteKind.command, 'nope'), isEmpty);
    });
  });

  group('bot commands', () {
    test('inserts the bots own prefix, not a slash', () {
      final row = _for(
        AutocompleteKind.command,
        'ping',
        botCommands: [_botCommand('b1', 'Helper', '!', 'ping')],
      ).first;
      expect(row.label, '!ping');
      expect(row.insert, '!ping ');
    });

    test('matches on the bare name, never the prefix', () {
      final rows = _for(
        AutocompleteKind.command,
        'ping',
        botCommands: [_botCommand('b1', 'Helper', '!', 'ping')],
      );
      expect(rows, hasLength(1));
    });

    test('detail names the bot, so two bots are told apart', () {
      final row = _for(
        AutocompleteKind.command,
        'ping',
        botCommands: [_botCommand('b1', 'Helper', '!', 'ping')],
      ).first;
      expect(row.detail, contains('Helper'));
    });

    test('a command of an offline bot is flagged and says so', () {
      final rows = _for(
        AutocompleteKind.command,
        'pi',
        botCommands: [
          const api.ChannelBotCommand(
            botUserId: 'b1',
            botUsername: 'Helper',
            botDisplayName: 'Helper',
            prefix: '!',
            name: 'ping',
            description: 'does ping things',
            offline: true,
          ),
        ],
      );
      expect(rows.single.offline, isTrue);
      expect(rows.single.detail, isNot(contains('offline')));
      expect(rows.single.insert, '!ping ', reason: 'still insertable');
    });

    test('two bots answering one trigger list only the first', () {
      final rows = _for(
        AutocompleteKind.command,
        'watch',
        botCommands: [
          _botCommand('b1', 'Jellyfin', '!', 'watch'),
          _botCommand('b2', 'Deals', '!', 'Watch'),
        ],
      );
      expect(rows, hasLength(1));
      expect(rows.single.detail, contains('Jellyfin'));
    });

    test('the same name under different prefixes stays two rows', () {
      final rows = _for(
        AutocompleteKind.command,
        'stop',
        botCommands: [
          _botCommand('b1', 'Music', '~', 'stop'),
          _botCommand('b2', 'Games', '!', 'stop'),
        ],
      );
      expect(rows.map((r) => r.label), ['~stop', '!stop']);
    });

    test('typing a bot prefix lists only the bots that use it', () {
      final rows = autocompleteSuggestions(
        query: const AutocompleteQuery(
          kind: AutocompleteKind.botCommand,
          term: 'st',
          start: 0,
          end: 3,
          prefix: '~',
        ),
        custom: const [],
        members: members,
        botCommands: [
          _botCommand('b1', 'Music', '~', 'stop'),
          _botCommand('b2', 'Games', '!', 'start'),
        ],
      );
      expect(rows.map((r) => r.label), ['~stop']);
    });
  });

  group('mention matching by display name', () {
    List<String> labels(String term, List<api.UserProfile> roster) =>
        autocompleteSuggestions(
          query: _q(AutocompleteKind.mention, term),
          custom: const [],
          members: roster,
        ).map((r) => r.insert).toList();

    test('a display name prefix beats usernames that merely contain it', () {
      final roster = [
        for (var i = 0; i < 9; i++) _member('u-$i', 'a${i}ki', 'Person $i'),
        _member('u-kiki', 'moderningot', 'Kiki'),
      ];
      expect(labels('ki', roster).first, '@moderningot ');
    });

    test('exact outranks prefix', () {
      final roster = [
        _member('u-1', 'kikiwi', 'Kikiwi'),
        _member('u-2', 'kiki', 'Other'),
      ];
      expect(labels('kiki', roster), ['@kiki ', '@kikiwi ']);
    });

    test('ignores case and accents', () {
      final roster = [_member('u-1', 'jo', 'José')];
      expect(labels('jose', roster), ['@jo ']);
      expect(labels('JOSÉ', roster.map((m) => m).toList()), ['@jo ']);
    });

    test('matches the start of a later word in a multi-word name', () {
      final roster = [
        _member('u-1', 'zed', 'Big Kiki'),
        _member('u-2', 'ski', 'Nobody'),
      ];
      expect(labels('ki', roster), ['@zed ', '@ski ']);
    });
  });

  group('a bot command option', () {
    api.ChannelBotCommand deals(List<String> choices) => api.ChannelBotCommand(
      botUserId: 'b1',
      botUsername: 'deals',
      botDisplayName: 'Deals',
      prefix: '!',
      name: 'sources',
      description: 'pick a store',
      options: [api.BotCommandOption(name: 'source', choices: choices)],
    );

    List<AutocompleteSuggestion> rows(
      String term,
      List<String> choices, {
      int argIndex = 0,
    }) => autocompleteSuggestions(
      query: AutocompleteQuery(
        kind: AutocompleteKind.botOption,
        term: term,
        start: 9,
        end: 9 + term.length,
        command: '!sources',
        argIndex: argIndex,
      ),
      custom: const [],
      members: members,
      botCommands: [deals(choices)],
    );

    test('lists every choice, uncapped, and inserts the choice', () {
      final choices = [for (var i = 0; i < 20; i++) 'store$i'];
      final all = rows('', choices);
      expect(all, hasLength(20));
      expect(all.first.insert, 'store0 ');
      expect(all.first.detail, 'source');
    });

    test('filters as you type, prefix matches first', () {
      final matches = rows('st', ['mist', 'gog', 'steam', 'epic']);
      expect(matches.map((r) => r.label), ['steam', 'mist']);
    });

    test('offers nothing past the last declared option', () {
      expect(rows('', ['steam'], argIndex: 1), isEmpty);
    });

    test('a free-form option offers nothing', () {
      expect(rows('', const []), isEmpty);
    });
  });
}
