// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Cross-checks `parseInline`'s `@[Role Name]` extraction against the same
/// table of tricky inputs the server asserts in `crates/slimm-server/src/
/// push/recipients.rs`'s `the_shared_role_fixture_agrees_with_message_inline_dart`.
///
/// Both sides read `crates/slimm-server/tests/fixtures/
/// role_mention_charset_cases.json`, the same shared-fixture shape
/// `message_inline_mention_charset_test.dart` already uses for the plain
/// `@name` grammar.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_inline.dart';

void main() {
  final repoRoot = _findRepoRoot(Directory.current);
  final fixture = File(
    '${repoRoot.path}/crates/slimm-server/tests/fixtures/role_mention_charset_cases.json',
  );

  test('the fixture exists and is not empty', () {
    expect(fixture.existsSync(), isTrue, reason: fixture.path);
    expect(_loadCases(fixture), isNotEmpty);
  });

  for (final testCase in _loadCases(fixture)) {
    test('role mentions in ${jsonEncode(testCase.content)}', () {
      expect(_roleMentionsIn(testCase.content), testCase.mentions);
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

/// The role names a real transcript render would resolve, collected by
/// walking the same tree `message_text.dart` walks rather than by a second
/// regex.
Set<String> _roleMentionsIn(String content) {
  final names = <String>{};
  void visit(List<InlineNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case InlineRoleMention(:final name):
          names.add(name);
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
        case InlineMention():
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
/// repo-root anchor `message_inline_mention_charset_test.dart` already uses.
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
