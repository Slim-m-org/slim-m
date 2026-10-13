// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `/gif`: which composed text asks for the picker, and the autocomplete row
/// that offers it only where a GIF provider is configured.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/composer_autocomplete_items.dart';
import 'package:slimm_app/src/widgets/composer_autocomplete_query.dart';
import 'package:slimm_app/src/widgets/composer_gif_command.dart';

List<String> _labels(String term, {required bool gifSearch}) =>
    autocompleteSuggestions(
      query: AutocompleteQuery(
        kind: AutocompleteKind.command,
        term: term,
        start: 0,
        end: term.length + 1,
      ),
      custom: const [],
      members: const [],
      gifSearch: gifSearch,
    ).map((s) => s.label).toList();

void main() {
  test('reads the search out of a /gif message', () {
    expect(gifCommandQuery('/gif'), '');
    expect(gifCommandQuery('/gif  cats on boats '), 'cats on boats');
    expect(gifCommandQuery('  /gif dog'), 'dog');
    expect(gifCommandQuery('/gifs'), isNull);
    expect(gifCommandQuery('look at this /gif'), isNull);
    expect(gifCommandQuery('/giphy'), isNull);
  });

  test('/gif is offered only with a GIF provider', () {
    expect(_labels('g', gifSearch: true), contains('/gif'));
    expect(_labels('', gifSearch: true).first, '/gif');
    expect(_labels('g', gifSearch: false), isNot(contains('/gif')));
    expect(_labels('sh', gifSearch: true), isNot(contains('/gif')));
  });
}
