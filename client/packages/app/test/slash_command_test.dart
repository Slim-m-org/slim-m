// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Module slash commands: recognizing `/name args` on send, and offering the
/// discovered commands in the composer autocomplete alongside the built-ins.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/slash_command.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_items.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_query.dart';

const _roll = api.SlashCommand(
  moduleId: 'dice',
  command: 'roll',
  name: 'roll',
  description: 'Roll dice like 2d20+3',
);

void main() {
  group('matchSlashCommand', () {
    test('returns null for a non-slash message', () {
      expect(matchSlashCommand(const [_roll], 'hello there'), isNull);
    });

    test('matches a known command and returns its arguments', () {
      final match = matchSlashCommand(const [_roll], '/roll 2d20+3');
      expect(match, isNotNull);
      expect(match!.$1.moduleId, 'dice');
      expect(match.$1.command, 'roll');
      expect(match.$2, '2d20+3');
    });

    test('matches with no arguments', () {
      final match = matchSlashCommand(const [_roll], '/roll');
      expect(match, isNotNull);
      expect(match!.$2, '');
    });

    test('is case-insensitive on the keyword and trims the arguments', () {
      final match = matchSlashCommand(const [_roll], '/ROLL   2d6  ');
      expect(match, isNotNull);
      expect(match!.$2, '2d6');
    });

    test('returns null for an unknown keyword', () {
      expect(matchSlashCommand(const [_roll], '/summon a demon'), isNull);
    });

    test('returns null when no commands are installed', () {
      expect(matchSlashCommand(const [], '/roll 2d6'), isNull);
    });

    test('matches nothing when two modules offer the same keyword', () {
      const other = api.SlashCommand(
        moduleId: 'other-dice',
        command: 'roll',
        name: 'Roll',
      );
      expect(matchSlashCommand(const [_roll, other], '/roll 2d6'), isNull);
      expect(clashingSlashKeyword(const [_roll, other], '/roll 2d6'), 'roll');
      expect(clashingSlashKeyword(const [_roll], '/roll 2d6'), isNull);
    });
  });

  group('command autocomplete', () {
    AutocompleteQuery query(String term) => AutocompleteQuery(
      kind: AutocompleteKind.command,
      term: term,
      start: 0,
      end: 0,
    );

    test('offers module commands after the built-in text ones', () {
      final rows = autocompleteSuggestions(
        query: query(''),
        custom: const [],
        members: const [],
        slashCommands: const [_roll],
      );
      final labels = rows.map((r) => r.label).toList();
      expect(labels, contains('/shrug'));
      expect(labels, contains('/roll'));
      final roll = rows.firstWhere((r) => r.label == '/roll');
      expect(roll.insert, '/roll ');
      expect(roll.detail, 'Roll dice like 2d20+3');
    });

    test('filters module commands by the typed prefix', () {
      final rows = autocompleteSuggestions(
        query: query('ro'),
        custom: const [],
        members: const [],
        slashCommands: const [_roll],
      );
      final labels = rows.map((r) => r.label).toList();
      expect(labels, contains('/roll'));
      expect(labels, isNot(contains('/shrug')));
    });
  });
}
