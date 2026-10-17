// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Cross-checks `parseInline`'s mention extraction against the same table of
/// tricky inputs the server asserts in `crates/slimm-server/src/push/
/// recipients.rs`'s `the_shared_charset_fixture_agrees_with_message_inline_dart`.
///
/// Both sides read `crates/slimm-server/tests/fixtures/
/// mention_charset_cases.json`, a single file rather than two hand-copied
/// lists, so a charset or trimming-rule edit on one side that is not made on
/// the other fails here or there - whichever the fixture no longer matches -
/// instead of only showing up as a mention that silently stops notifying
/// people on one platform.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_inline.dart';

void main() {
  final repoRoot = _findRepoRoot(Directory.current);
  final fixture = File(
    '${repoRoot.path}/crates/slimm-server/tests/fixtures/mention_charset_cases.json',
  );

  test('the fixture exists and is not empty', () {
    expect(fixture.existsSync(), isTrue, reason: fixture.path);
    expect(_loadCases(fixture), isNotEmpty);
  });

  for (final testCase in _loadCases(fixture)) {
    test('mentions in ${jsonEncode(testCase.content)}', () {
      expect(_mentionsIn(testCase.content), testCase.mentions);
    });
  }
}

class _Case {
  const _Case(this.content, this.mentions);
  final String content;
  final Set<String> mentions;
}

List<_Case> _loadCases(File fixture) {
  final raw = jsonDecode(fixture.readAsStringSync()) as List<dynamic>;
  return [
    for (final entry in raw.cast<Map<String, dynamic>>())
      _Case(
        entry['content'] as String,
        (entry['mentions'] as List<dynamic>).cast<String>().toSet(),
      ),
  ];
}

/// The `@name`s a real transcript render would resolve, collected by walking
/// the same tree `message_text.dart` walks rather than by a second regex, so
/// this proves what the parser actually does and not what a copy of it does.
Set<String> _mentionsIn(String content) {
  final names = <String>{};
  void visit(List<InlineNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case InlineMention(:final raw):
          names.add(raw.substring(1));
        case InlineBold(:final children):
          visit(children);
        case InlineItalic(:final children):
          visit(children);
        case InlineStrikethrough(:final children):
          visit(children);
        case InlineSpoiler(:final children):
          visit(children);
        case InlineText():
        case InlineCode():
        case InlineEmoji():
        case InlineRoleMention():
        case InlineLink():
        case InlineMessageLink():
        case InlineChannelMention():
          break;
      }
    }
  }

  visit(parseInline(content));
  return names;
}

/// Walks upward from [start] looking for schema/openapi.yaml, the same
/// repo-root anchor `client/packages/api/test/schema_coverage_test.dart`
/// already uses, so this test does not depend on whether it was invoked from
/// the repo root, from client/, or from client/packages/app.
Directory _findRepoRoot(Directory start) {
  var dir = start.absolute;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/schema/openapi.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'could not find schema/openapi.yaml walking up from ${start.path}; is '
    'this test running from somewhere inside the slim-m repo?',
  );
}
