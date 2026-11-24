// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Flutter-owned widgets each drive their own entrance or expansion
/// with a plain `AnimationController` the framework creates internally, keyed
/// to the platform's own reduce-motion accessibility feature - never to this
/// app's [MotionOverride], which only ever reaches `MediaQuery` and cannot
/// touch a controller Flutter owns.
///
/// Found by hand, once each, in `showAppSheet` (`sheet.dart`), the compact
/// branch of `showMemberProfile` (`member_profile.dart`), and the debug
/// log's `ExpansionTile` (`debug_log_screen.dart`); the desktop popover a few
/// lines below the second of those already routed `transitionDuration`
/// straight through `AppMotion.reduced`, which is what `showGeneralDialog`'s
/// own inclusion below is modelled on. This is the sweep those three fixes
/// did not leave behind anywhere else, the same shape
/// `type_scale_literal_test.dart` already keeps for an off-scale font size.
///
/// Each call's own balanced argument list must carry its override, so a
/// sibling call in the same file cannot vouch for one that does not.
///
/// The `ScaffoldMessenger.showSnackBar` rule closes the same gap for a
/// SnackBar, one layer later: fourteen call sites once reached
/// `ScaffoldMessenger` directly, each dropping the override on its own. The app
/// no longer builds a SnackBar at all (every message is a toast), so this rule
/// only keeps a future raw call from reintroducing the original bug (no
/// override at all); a raw call carrying `snackBarAnimationStyle:` still passes.
///
/// Sources are read through `codeOnly` (`slimm_test_support`), so a comment
/// or string naming a call or its override is neither.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slimm_test_support/source_gates.dart';

class _Rule {
  const _Rule(this.name, this.call, this.override);

  /// What a failure names this widget as.
  final String name;

  /// The widget's own call or constructor, generics included.
  final RegExp call;

  /// The keyword argument that carries `AppMotion` through to it.
  final Pattern override;
}

final _rules = [
  _Rule(
    'showInWindowDialog',
    RegExp(r'(?<!\?>\s)\bshowInWindowDialog(<[^>]*>)?\('),
    'animationStyle:',
  ),
  _Rule(
    'showModalBottomSheet',
    RegExp(r'\bshowModalBottomSheet(<[^>]*>)?\('),
    'sheetAnimationStyle:',
  ),
  _Rule(
    'showGeneralDialog',
    RegExp(r'\bshowGeneralDialog(<[^>]*>)?\('),
    'transitionDuration:',
  ),
  _Rule(
    'showDialog',
    RegExp(r'\bshowDialog(<[^>]*>)?\('),
    'animationStyle:',
  ),
  _Rule(
    'showMenu',
    RegExp(r'\bshowMenu(<[^>]*>)?\('),
    'popUpAnimationStyle:',
  ),
  _Rule(
    'PopupMenuButton',
    RegExp(r'\bPopupMenuButton(<[^>]*>)?\('),
    'popUpAnimationStyle:',
  ),
  _Rule('ExpansionTile', RegExp(r'\bExpansionTile\('),
      'expansionAnimationStyle:'),
  _Rule(
    'ScaffoldMessenger.showSnackBar',
    RegExp(r'\.showSnackBar\('),
    'snackBarAnimationStyle:',
  ),
  // AppMotion.reduced's zero duration trips AnimatedSize's layout assertion; reducedSize exists for it.
  _Rule(
    'AnimatedSize',
    RegExp(r'\bAnimatedSize\('),
    RegExp(r'AppMotion\.(reducedSize|isReduced)\('),
  ),
];

/// A short, named allowlist rather than a growing one: each entry would
/// carry its own one-line "why" in the source, the same discipline
/// `type_scale_literal_test.dart` already holds everyone else to.
const _exceptions = <String>{};

Iterable<File> _clientSources() sync* {
  for (final pkg in Directory('..').listSync().whereType<Directory>()) {
    final lib = Directory('${pkg.path}/lib');
    if (!lib.existsSync()) continue;
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart')) yield file;
    }
  }
}

/// One entry per call in [source] whose own argument list lacks its override.
List<String> _unguardedCalls(String source) {
  final code = codeOnly(source);
  return [
    for (final rule in _rules)
      for (final match in rule.call.allMatches(code))
        if (rule.override
            .allMatches(
              callArguments(code, match.end - 1) ?? code.substring(match.end),
            )
            .isEmpty)
          '${rule.name} on line '
              '${'\n'.allMatches(code.substring(0, match.start)).length + 1}',
  ];
}

void main() {
  test(
    'every Flutter-owned dialog, sheet or expansion carries this app\'s own '
    'reduce-motion override',
    () {
      final offenders = <String>[];
      for (final file in _clientSources()) {
        if (_exceptions.contains(file.path)) continue;
        for (final call in _unguardedCalls(file.readAsStringSync())) {
          offenders.add('${file.path}: $call');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'a Flutter-owned dialog/sheet/expansion with no in-app '
            'reduce-motion override - route its duration through '
            'AppMotion.reduced or AnimationStyle.noAnimation, or add a '
            'one-line "why" comment and list the file in _exceptions:\n'
            '${offenders.join('\n')}',
      );
    },
  );

  test('a call is judged by its own arguments, not by its file', () {
    const guarded = 'showModalBottomSheet(sheetAnimationStyle: x, builder: b);';
    const bare = 'showModalBottomSheet(builder: b);';
    expect(_unguardedCalls(guarded), isEmpty);
    expect(_unguardedCalls(bare), hasLength(1));
    expect(_unguardedCalls('$guarded\n$bare'), hasLength(1));
  });

  test('a comment naming a call or its override is neither', () {
    expect(
        _unguardedCalls('// showDialog(x) and sheetAnimationStyle:'), isEmpty);
    expect(
      _unguardedCalls('showDialog(builder: b); // animationStyle: x'),
      hasLength(1),
    );
  });

  test('showDialog, showMenu and PopupMenuButton are rules', () {
    expect(_unguardedCalls('showDialog<void>(builder: b);'), hasLength(1));
    expect(_unguardedCalls('showMenu<int>(items: i);'), hasLength(1));
    expect(
        _unguardedCalls('PopupMenuButton<int>(itemBuilder: b);'), hasLength(1));
    expect(
      _unguardedCalls(
          'PopupMenuButton(popUpAnimationStyle: s, itemBuilder: b);'),
      isEmpty,
    );
  });
}
