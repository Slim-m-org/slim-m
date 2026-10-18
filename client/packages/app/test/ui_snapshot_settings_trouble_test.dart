// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting, Debug log and About panes beside the settings nav, at
/// desktop and phone width, so the redesign is checked against pixels.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/routing/routes.dart';

import 'ui_snapshot_support.dart';

DebugLog _populated() => DebugLog()
  ..record('flutter', 'Info message, no detail', level: DiagnosticSeverity.info)
  ..record(
    'platform',
    'Warning message',
    level: DiagnosticSeverity.warning,
    detail: 'A platform detail',
  )
  ..record(
    'voice',
    'Error message',
    detail: 'Detail / stack trace, selectable\nline 2\nline 3',
  );

Future<void> _openPane(WidgetTester tester, String label) async {
  // The nav row; the pane's own heading repeats the label once it is open.
  await tester.tap(find.text(label).first);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _openTrouble(WidgetTester tester) =>
    _openPane(tester, 'Troubleshooting');

Future<void> _openAbout(WidgetTester tester) =>
    _openPane(tester, 'About slim-m');

Future<void> _openDebugLog(WidgetTester tester) async {
  await _openTrouble(tester);
  await tester.tap(find.text('Debug log'));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _openDebugLogAndExpand(WidgetTester tester) async {
  await _openDebugLog(tester);
  await tester.tap(find.byTooltip('Show detail').first);
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);

  final cases =
      <
        String,
        ({
          String pane,
          List<Override> Function() overrides,
          Future<void> Function(WidgetTester)? after,
        })
      >{
        'trouble': (
          pane: 'troubleshooting',
          overrides: () => [],
          after: _openTrouble,
        ),
        'about': (pane: 'about', overrides: () => [], after: _openAbout),
        'debuglog-empty': (
          pane: 'troubleshooting',
          overrides: () => [],
          after: _openDebugLog,
        ),
        'debuglog-entries': (
          pane: 'troubleshooting',
          overrides: () => [
            debugLogProvider.overrideWith((ref) => _populated()),
          ],
          after: _openDebugLogAndExpand,
        ),
      };

  for (final theme in const ['dark']) {
    for (final c in cases.entries) {
      for (final viewport in const ['desktop', 'phone-portrait']) {
        testWidgets('settings ${c.key} at $viewport ($theme)', (tester) async {
          await renderSurface(
            tester,
            Routes.personalSettingsPane(c.value.pane),
            viewport,
            theme,
            'settings-${c.key}-$viewport-$theme',
            overrides: c.value.overrides(),
            afterSettle: viewport == 'desktop'
                ? c.value.after
                : (t) => _openPane(
                    t,
                    c.value.pane == 'about'
                        ? 'About slim-m'
                        : 'Troubleshooting',
                  ),
          );
        });
      }
    }
  }
}
