// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that the composer lifts its content off the home indicator.
///
/// This is the bottom edge of the compact conversation screen, and it had no
/// test at all: the inset could be removed with the whole suite still green.
/// The send button alone does not prove it, measured at 796 against a safe
/// bottom of 810 with the inset gone, so this asserts on the composer's whole
/// content box, whose last row is the typing and newline hints.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/typing_controller.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_design_system/design_system.dart';

/// An iPhone with a home indicator, in logical points.
const double _topInset = 47;
const double _bottomInset = 34;
const double _viewWidth = 390;
const double _viewHeight = 844;

/// Stands in for the real controller, which would open a websocket
/// subscription the moment the first keystroke reaches it.
class _NoopTyping extends StateNotifier<Set<String>>
    implements TypingController {
  _NoopTyping() : super(const {});

  @override
  void notifyTyping() {}
}

/// Everything the composer lays out, bounded by its own outermost [Column].
/// The card is not enough on its own: the hint row sits below it.
Finder _composerContent() => find
    .descendant(of: find.byType(Composer), matching: find.byType(Column))
    .first;

Future<void> _pumpComposer(
  WidgetTester tester,
  TextEditingController controller,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(_viewWidth, _viewHeight);
  tester.view.padding = const FakeViewPadding(
    top: _topInset,
    bottom: _bottomInset,
  );
  tester.view.viewPadding = const FakeViewPadding(
    top: _topInset,
    bottom: _bottomInset,
  );
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        typingControllerProvider.overrideWith((ref, _) => _NoopTyping()),
      ],
      child: MaterialApp(
        theme: buildTheme(
          Brightness.light,
          AppTokens.light,
        ).copyWith(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              Composer(
                controller: controller,
                channelId: 'c1',
                channelName: 'general',
                onSend: (_) async {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late TextEditingController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
  });

  tearDown(() => controller.dispose());

  testWidgets('the composer keeps its content clear of the home indicator', (
    tester,
  ) async {
    await _pumpComposer(tester, controller);

    expect(
      tester.getRect(_composerContent()).bottom,
      lessThanOrEqualTo(_viewHeight - _bottomInset),
      reason: 'the send row painted under the home indicator before this',
    );
  });

  testWidgets(
    'the composer reserves the inset rather than merely fitting in it',
    (tester) async {
      await _pumpComposer(tester, controller);

      final composer = tester.getRect(find.byType(Composer));
      expect(
        composer.bottom - tester.getRect(_composerContent()).bottom,
        greaterThanOrEqualTo(_bottomInset),
        reason:
            'the gap below the content is what the inset buys; without it '
            'the composer would only be as clear as its own 12pt padding',
      );
    },
  );
}
