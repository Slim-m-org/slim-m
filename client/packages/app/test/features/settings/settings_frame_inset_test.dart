// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0013's one rule about layout: horizontal inset is owned by the
/// screen frame, never by a section or a screen re-deriving it by hand.
/// `categories_screen.dart` broke it by coincidence rather than intent -
/// `SettingsScreenScaffold(padding: EdgeInsets.zero)` plus its own
/// `ListView(padding: EdgeInsets.all(AppSpacing.s16))` landed back on the
/// same 16px the frame would have given it for free - and nothing caught it
/// until a review read the file by hand.
///
/// This reads a screen's own source the way `type_scale_literal_test.dart`
/// (design_system) reads for an off-scale `fontSize:` literal: a case this
/// cannot see is a case that was never written the wrong way, so it cannot
/// go stale the way a hand-kept list would.
///
/// Scoped to what a source scan can actually prove cheaply: an explicit
/// `padding:` argument on a `SettingsScreenScaffold(...)` call, and a
/// `Padding` wrapped directly around its `child:` before the frame ever sees
/// it. `SettingsPanesScaffold` takes no `padding` parameter at all - its pane
/// body always pads at `AppSpacing.s16` - so the only way a pane could
/// re-derive its own inset is inside a `SettingsPane.builder` closure, which
/// may be defined anywhere and is not something a scan of the scaffold call
/// site itself can see. That residual is real and is left unenforced rather
/// than approximated; see docs/decisions/0013-settings-container-system.md.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/code_only.dart';

/// A named allowlist, each entry carrying its own one-line why - the
/// `type_scale_literal_test.dart` shape. `reports_screen.dart` genuinely
/// cannot use the frame's own `ListView`: its trailing load-more row needs a
/// real `itemBuilder`/`itemCount` a single wrapped child cannot express, so
/// it owns its own scroll and pads it to match the frame's own AppSpacing.s16
/// by hand rather than by inheritance.
const _exceptions = {
  'lib/src/features/settings/screens/admin/reports_screen.dart',
};

/// The file the widget itself is declared in: its own default parameter
/// value is not a caller passing an override.
const _declaringFile =
    'lib/src/features/settings/screens/settings_screen_scaffold.dart';

/// Finds the substring from [start] (the character right after an opening
/// `(`) to its matching close paren, so a check can look only inside one
/// constructor call rather than the rest of the file.
String _balancedCall(String source, int openParenIndex) {
  var depth = 1;
  var i = openParenIndex + 1;
  while (i < source.length && depth > 0) {
    if (source[i] == '(') depth++;
    if (source[i] == ')') depth--;
    i++;
  }
  return source.substring(openParenIndex, i);
}

/// Drops every character nested two or more brackets deep in [call], so a
/// regex run over the result only ever matches one of the call's own
/// top-level named arguments - never a same-shaped `padding:` three widgets
/// down inside `child:`, which a screen's own content is free to use for
/// reasons this test has no business judging.
///
/// [call] is [_balancedCall]'s own result, so it opens at depth 0 and its
/// first character is the call's own `(`, putting everything up to the next
/// nested `(`/`[`/`{` at depth 1 - the call's own argument list.
String _topLevelOnly(String call) {
  final kept = StringBuffer();
  var depth = 0;
  for (final c in call.split('')) {
    final closes = c == ')' || c == ']' || c == '}';
    if (closes) depth--;
    if (depth <= 1) kept.write(c);
    if (c == '(' || c == '[' || c == '{') depth++;
  }
  return kept.toString();
}

void main() {
  test("codeOnly does not let a comment's own stray paren close "
      'a call early, and leaves a string literal containing one alone too', () {
    const withCommentParen =
        "title: 'Roles', // matching parens here, ok :)\n"
        '      padding: EdgeInsets.zero,';
    final scanned = codeOnly(withCommentParen);
    expect(
      RegExp(r'\bpadding\s*:').hasMatch(scanned),
      isTrue,
      reason:
          "a stray ')' inside a // comment must not end the balanced-"
          'paren scan before the real padding: argument is reached',
    );

    const withStringParen = "title: 'Say :) here', padding: EdgeInsets.zero";
    expect(
      RegExp(r'\bpadding\s*:').hasMatch(codeOnly(withStringParen)),
      isTrue,
    );
    final depth =
        codeOnly(withStringParen).split('(').length -
        codeOnly(withStringParen).split(')').length;
    expect(
      depth,
      0,
      reason:
          "a ':)' inside a string literal must not read as a real "
          'unmatched close paren either',
    );
  });

  test('_topLevelOnly keeps a top-level padding: and drops a nested one, so a '
      'screen that legitimately uses Padding somewhere inside its own content '
      'cannot false-positive this gate', () {
    const nested =
        "(title: 'X', child: Column(children: [Padding(padding: "
        "EdgeInsets.all(8), child: Text('a'))]))";
    final scrubbed = _topLevelOnly(nested);
    expect(
      RegExp(r'\bpadding\s*:').hasMatch(scrubbed),
      isFalse,
      reason:
          'the only padding: here belongs to an unrelated nested '
          'Padding three levels into child:, not to the scaffold itself',
    );

    const topLevel = "(title: 'X', padding: EdgeInsets.zero, child: Y())";
    expect(RegExp(r'\bpadding\s*:').hasMatch(_topLevelOnly(topLevel)), isTrue);
  });

  test('no SettingsScreenScaffold call overrides the frame\'s own inset', () {
    final screensDir = Directory('lib/src');
    expect(
      screensDir.existsSync(),
      isTrue,
      reason: 'run this from the app package root',
    );

    final callSite = RegExp(r'SettingsScreenScaffold\(');
    final offenders = <String>[];

    for (final file in screensDir.listSync(recursive: true).whereType<File>()) {
      // Every screens folder: the shared one and each feature's.
      if (!file.path.endsWith('.dart') || !file.path.contains('/screens/')) {
        continue;
      }
      final relative = file.path.replaceFirst(RegExp(r'^\./'), '');
      if (relative == _declaringFile) continue;

      final source = codeOnly(file.readAsStringSync());
      for (final match in callSite.allMatches(source)) {
        final call = _topLevelOnly(_balancedCall(source, match.end - 1));
        if (_exceptions.contains(relative)) continue;

        if (RegExp(r'\bpadding\s*:').hasMatch(call)) {
          offenders.add('$relative: passes its own padding:');
        }
        if (RegExp(r'child\s*:\s*Padding\(').hasMatch(call)) {
          offenders.add(
            '$relative: wraps child in Padding before the frame sees it',
          );
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'decision 0013: horizontal inset belongs to the frame alone. A '
          'screen with a genuine reason to own its own scroll or padding '
          'gets a one-line "why" in _exceptions, the same discipline '
          'type_scale_literal_test.dart already holds fontSize literals '
          'to:\n${offenders.join('\n')}',
    );
  });
}
