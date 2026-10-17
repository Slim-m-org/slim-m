// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Four Flutter-owned widgets each drive their own entrance or expansion
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
/// A per-file occurrence count, not a per-call parse: cheap, and every rule
/// here already holds file-wide today, so a call that carries the override
/// and a sibling call in the same file that does not would pass this gate
/// undetected. That trade is the one `type_scale_literal_test.dart` already
/// made for the same reason - a real parser is a second thing to maintain
/// and drift from the grammar it parses.
///
/// The `ScaffoldMessenger.showSnackBar` rule closes the same gap for a
/// SnackBar, one layer later: `app_snackbar.dart`'s own `showAppSnackbar` is
/// the one place fourteen call sites used to reach `ScaffoldMessenger`
/// directly, each dropping the override on its own. This rule does not by
/// itself force a caller through that one function - a raw call anywhere
/// carrying `snackBarAnimationStyle:` still passes - but it does mean a
/// future call site cannot reintroduce the original bug (no override at
/// all) without either using `showAppSnackbar` or writing the override out
/// by hand and losing the whole point of a shared helper.
///
/// Counts run over `support/code_only.dart`'s comment/string-stripped text,
/// not the raw file: a per-file count comparison is exactly the shape a
/// comment can defeat by inflating one side without touching the other,
/// and reproduced directly - a genuine `showDialog(...)` call with no real
/// override, plus a `// TODO: this should carry animationStyle:
/// AnimationStyle.noAnimation` comment anywhere else in the same file,
/// passed silently before this existed.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/code_only.dart';

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
    RegExp(r'\bshowInWindowDialog(<[^>]*>)?\('),
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

void main() {
  test(
    'every Flutter-owned dialog, sheet or expansion carries this app\'s own '
    'reduce-motion override',
    () {
      final designSystemLib = Directory('lib');
      expect(
        designSystemLib.existsSync(),
        isTrue,
        reason: 'run this from the design_system package root',
      );
      final appLib = Directory('../app/lib');
      expect(
        appLib.existsSync(),
        isTrue,
        reason: 'expected a sibling app package at ../app',
      );

      final offenders = <String>[];
      for (final dir in [designSystemLib, appLib]) {
        for (final file in dir.listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          if (_exceptions.contains(file.path)) continue;
          final source = codeOnly(file.readAsStringSync());
          for (final rule in _rules) {
            final calls = rule.call.allMatches(source).length;
            if (calls == 0) continue;
            final overrides = rule.override.allMatches(source).length;
            if (calls > overrides) {
              offenders.add(
                '${file.path}: ${rule.name} appears $calls time(s) but '
                'its override only $overrides time(s)',
              );
            }
          }
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
}
