// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hovered message's time and the full date its tooltip shows take the
/// current theme's colours, in the header and the continuation gutter alike:
/// the tooltip once drew an inverted plate, white in dark and black in light.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/format.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _epoch = 1700000000000;

Widget _row(Brightness brightness, {required bool grouped}) => ProviderScope(
  overrides: [
    timeFormatControllerProvider.overrideWith(
      (ref) => TimeFormatController(ref)..state = TimeFormatPreference.h24,
    ),
  ],
  child: MaterialApp(
    theme: brightness == Brightness.dark
        ? buildTheme(Brightness.dark, AppTokens.dark)
        : buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: MessageRow(
        message: message(createdAt: _epoch),
        grouped: grouped,
        showNewDivider: false,
        knownUsernames: const {},
        actions: noActions,
        editing: false,
        callbacks: MessageRowCallbacks(
          onRetry: noop,
          onDiscard: noop,
          onPickReaction: (_) {},
          onReactionTap: (_) {},
          onVote: (_) {},
          onSubmitEdit: (_) {},
          onCancelEdit: noop,
        ),
      ),
    ),
  ),
);

Color? _colourOf(WidgetTester tester, Finder text) {
  final style = DefaultTextStyle.of(
    tester.element(text),
  ).style.merge(tester.widget<Text>(text).style);
  return style.color;
}

void main() {
  for (final brightness in Brightness.values) {
    for (final grouped in [false, true]) {
      final where = grouped ? 'gutter' : 'header';
      testWidgets('time and its tooltip follow ${brightness.name} ($where)', (
        tester,
      ) async {
        final tokens = brightness == Brightness.dark
            ? AppTokens.dark
            : AppTokens.light;
        await tester.pumpWidget(_row(brightness, grouped: grouped));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getCenter(find.byWidgetPredicate((w) => w is MessageRow)),
        );
        await tester.pump(const Duration(seconds: 1));
        await mouse.moveTo(
          tester.getCenter(find.byWidgetPredicate((w) => w is MessageTimeMark)),
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 300));

        final time = find.text(formatMessageTime(_epoch, use24Hour: true));
        expect(_colourOf(tester, time.first), tokens.textSecondary);

        final full = find.text(formatDateTime(_epoch, use24Hour: true));
        expect(full, findsOneWidget);
        expect(_colourOf(tester, full), tokens.textPrimary);
        final plate = tester.widget<DecoratedBox>(
          find
              .ancestor(
                of: full,
                matching: find.byWidgetPredicate((w) => w is DecoratedBox),
              )
              .first,
        );
        expect((plate.decoration as BoxDecoration).color, tokens.surfaceRaised);
      });
    }
  }
}
