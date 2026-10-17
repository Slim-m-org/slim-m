// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `SettingsNotice` and `SettingsAbsentValue` had no test of their own
/// contract before this: both were only reached indirectly through screen
/// tests (`space_settings_section_test.dart`, `debug_log_screen_frame_test.dart`)
/// that assert about the screen around them, never about what these two
/// widgets themselves guarantee. `SettingsAbsentValue` in particular had zero
/// coverage anywhere - its only caller, `removed_members_screen.dart`, has no
/// test file of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_notice.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

void main() {
  group('SettingsNotice', () {
    testWidgets('renders the message and defaults to the info glyph', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(const SettingsNotice(message: 'Nothing here yet.')),
      );

      expect(find.text('Nothing here yet.'), findsOneWidget);
      expect(find.byIcon(AppIcons.info), findsOneWidget);
    });

    testWidgets('a detail renders as a second line, under the message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const SettingsNotice(
            message: 'No access.',
            detail: 'Ask an administrator to grant it.',
          ),
        ),
      );

      expect(find.text('Ask an administrator to grant it.'), findsOneWidget);
      expect(
        tester.getRect(find.text('Ask an administrator to grant it.')).top,
        greaterThan(tester.getRect(find.text('No access.')).bottom),
      );
    });

    testWidgets('omitting detail renders no second line at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(const SettingsNotice(message: 'No access.')),
      );

      // Only the message's own Text: nothing stands in for a detail that was never given.
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('a custom icon overrides the default info glyph', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const SettingsNotice(message: 'Empty.', icon: AppIcons.delete),
        ),
      );

      expect(find.byIcon(AppIcons.info), findsNothing);
      expect(find.byIcon(AppIcons.delete), findsOneWidget);
    });

    testWidgets('centres in whatever space it is given', (tester) async {
      await tester.pumpWidget(
        _harness(
          const SizedBox(
            width: 400,
            height: 300,
            child: SettingsNotice(message: 'Nothing here yet.'),
          ),
        ),
      );

      final box = tester.getRect(find.byType(SizedBox).first);
      final text = tester.getRect(find.text('Nothing here yet.'));

      expect(text.center.dx, closeTo(box.center.dx, 1));
    });
  });

  group('SettingsAbsentValue', () {
    testWidgets('renders the given text, muted and italic', (tester) async {
      await tester.pumpWidget(
        _harness(const SettingsAbsentValue('No reason given.')),
      );

      const tokens = AppTokens.light;
      final rendered = tester.widget<Text>(find.text('No reason given.'));

      expect(rendered.style?.color, tokens.textSecondary);
      expect(
        rendered.style?.fontStyle,
        FontStyle.italic,
        reason:
            'italic is the one signal telling this apart from an ordinary '
            'caption line at a glance, since both share the muted colour',
      );
    });
  });
}
