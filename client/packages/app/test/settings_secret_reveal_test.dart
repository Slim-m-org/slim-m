// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared once-only secret card and the pieces the Addons panes build on.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/widgets/bot_permission_toggles.dart';
import 'package:slimm_app/src/widgets/settings_info_line.dart';
import 'package:slimm_app/src/widgets/settings_secret_reveal.dart';
import 'package:slimm_app/src/widgets/settings_section_header.dart';
import 'package:slimm_design_system/design_system.dart';

AppToggle _toggle(WidgetTester tester, String label) => tester
    .widgetList<AppToggle>(find.byType(AppToggle))
    .firstWhere((t) => t.semanticLabel == label);

Future<void> _pump(WidgetTester tester, Widget child, {int mine = 0}) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [myPermissionsProvider.overrideWithValue(mine)],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );

void main() {
  testWidgets('the secret copies to the clipboard and Done dismisses it', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    var dismissed = false;
    await _pump(
      tester,
      SettingsSecretReveal(
        warning: 'Shown once.',
        value: 'slimbot_secret',
        valueSemanticsLabel: 'Bot token',
        copyLabel: 'Copy token',
        onDismiss: () => dismissed = true,
      ),
    );
    expect(find.text('slimbot_secret'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Copy token'));
    expect(copied, 'slimbot_secret');
    await tester.tap(find.widgetWithText(AppButton, 'Done'));
    expect(dismissed, isTrue);
  });

  testWidgets('an info line is one inset sentence, warn tone on request', (
    tester,
  ) async {
    await _pump(
      tester,
      const SettingsSectionCard(
        children: [SettingsInfoLine('Heads up.', warn: true)],
      ),
    );
    final tokens = AppTokens.dark;
    final text = tester.widget<Text>(find.text('Heads up.'));
    expect(text.style?.color, tokens.warnText);
    final icon = find.byIcon(AppIcons.warning);
    expect(tester.widget<Icon>(icon).color, tokens.warnText);
    expect(
      tester.getTopLeft(icon).dx -
          tester.getTopLeft(find.byType(SettingsInfoLine)).dx,
      AppSpacing.s16,
    );
  });

  group('BotPermissionToggles', () {
    testWidgets('a held bit toggles and reports the new mask', (tester) async {
      int? next;
      await _pump(
        tester,
        BotPermissionToggles(value: 0, onChanged: (v) => next = v),
        mine: Perm.sendMessages,
      );
      _toggle(tester, 'Send messages').onChanged!(true);
      expect(next, Perm.sendMessages);
    });

    testWidgets('turning a bit off clears only that bit', (tester) async {
      int? next;
      await _pump(
        tester,
        BotPermissionToggles(
          value: Perm.sendMessages | Perm.viewChannel,
          onChanged: (v) => next = v,
        ),
        mine: Perm.sendMessages | Perm.viewChannel,
      );
      _toggle(tester, 'Send messages').onChanged!(false);
      expect(next, Perm.viewChannel);
    });

    testWidgets('a bit the viewer lacks is locked', (tester) async {
      int? next;
      await _pump(
        tester,
        BotPermissionToggles(value: 0, onChanged: (v) => next = v),
        mine: Perm.viewChannel,
      );
      final toggles = tester.widgetList<AppToggle>(find.byType(AppToggle));
      final locked = toggles.where((t) => t.onChanged == null).length;
      expect(locked, Perm.editable.length - 1);
      expect(_toggle(tester, 'Send messages').onChanged, isNull);
      expect(_toggle(tester, 'View channels').onChanged, isNotNull);
      expect(next, isNull);
    });
  });
}
