// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two things the debug log broke from its own family on, both from the
/// per-screen review (`docs/reports/screen-review/settings.md`).
///
/// It built its own `Scaffold`/`AppBar` rather than going through
/// `SettingsScreenScaffold` like its eleven siblings, which cost it
/// `BackToButton`'s named "Back to X" tooltip - the only thing that says
/// where the back button goes.
///
/// And it encoded entry severity in the category label's colour alone, the
/// one place in this whole area that carried state on a single channel. The
/// label text is the *source* ("flutter", "platform", "voice"), not the
/// severity, and the same source logs at any severity, so nothing else on the
/// row distinguished an error from an info line.
///
/// Both are asserted structurally rather than by pixel: a colour assertion
/// would pass for a screen reader that still hears nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/features/settings/screens/debug_log_screen.dart';
import 'package:slimm_app/src/features/settings/screens/settings_screen_scaffold.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(DebugLog Function() build) => ProviderScope(
  overrides: [debugLogProvider.overrideWith((ref) => build())],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const DebugLogScreen(),
  ),
);

DebugLog _oneOfEach() => DebugLog()
  ..record('voice', 'reconnected', level: DiagnosticSeverity.info)
  ..record('platform', 'unsupported', level: DiagnosticSeverity.warning)
  ..record('flutter', 'overflowed', level: DiagnosticSeverity.error);

void main() {
  testWidgets('goes through the shared settings frame, so it carries the '
      'named back tooltip its siblings do', (tester) async {
    await tester.pumpWidget(_harness(_oneOfEach));
    await tester.pumpAndSettle();

    expect(
      find.byType(SettingsScreenScaffold),
      findsOneWidget,
      reason:
          'its own Scaffold lost BackToButton, and a bare arrow names no '
          'destination to anyone who cannot see where they came from',
    );
    expect(find.byTooltip('Back to settings'), findsOneWidget);
  });

  testWidgets('severity is never carried by colour alone', (tester) async {
    await tester.pumpWidget(_harness(_oneOfEach));
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();
    await tester.pumpAndSettle();
    for (final word in ['Error', 'Warning', 'Info']) {
      expect(
        find.bySemanticsLabel(RegExp('^$word,')),
        findsOneWidget,
        reason:
            '$word must be readable as text, not inferred from a tint. A '
            'source label ("flutter") is not a severity: the same source logs '
            'at any of the three.',
      );
    }
    semantics.dispose();
  });

  testWidgets('each severity draws its own silhouette, not three tints of '
      'one glyph', (tester) async {
    await tester.pumpWidget(_harness(_oneOfEach));
    await tester.pumpAndSettle();

    final icons = tester
        .widgetList<Icon>(find.byType(Icon))
        .map((i) => i.icon)
        .toSet();

    for (final expected in [AppIcons.danger, AppIcons.warning, AppIcons.info]) {
      expect(
        icons,
        contains(expected),
        reason:
            'the AppStatusDot precedent: an octagon, a triangle and a circle '
            'survive greyscale where three colours do not',
      );
    }
  });

  testWidgets('an empty log states the reason rather than rendering blank', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(DebugLog.new));
    await tester.pumpAndSettle();

    expect(find.text('Nothing has gone wrong this session'), findsOneWidget);
  });
}
