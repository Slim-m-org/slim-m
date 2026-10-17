// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The compact quote itself: what it shows when the parent resolved, and -
/// the property that matters - what it refuses to show when it did not.
///
/// `reply_quote_honesty_test.dart` drives the same widget through a real
/// channel screen, for the blocked-author and deleted-parent cases
/// specifically; this file is the plain rendering contract underneath both.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_quote.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

void main() {
  testWidgets('a resolved parent shows its author and a snippet', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        ReplyQuote(
          resolved: message(
            id: 'parent',
            authorId: 'priya',
            authorDisplayName: 'Priya',
            content: 'the original text',
          ),
          onTap: () {},
        ),
      ),
    );

    // Author label and snippet are two separate Text widgets now, not one merged Text.rich.
    expect(find.textContaining('Priya'), findsOneWidget);
    expect(find.textContaining('the original text'), findsOneWidget);
    expect(find.text('Message unavailable'), findsNothing);
  });

  testWidgets('an unresolved parent names neither an author nor any content', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(const ReplyQuote(resolved: null, onTap: _noop)),
    );

    expect(find.text('Message unavailable'), findsOneWidget);
    // Nothing from a real message can appear: there is no message to draw it from.
    expect(find.text('Priya'), findsNothing);
  });

  testWidgets('a long parent is cut to one line, not spilled in full', (
    tester,
  ) async {
    final long = List.filled(200, 'word').join(' ');
    await tester.pumpWidget(
      harness(
        ReplyQuote(
          resolved: message(id: 'parent', content: long),
          onTap: () {},
        ),
      ),
    );

    expect(find.text(long), findsNothing, reason: 'a quote is compact');
  });

  testWidgets(
    'a long real display name does not overflow a phone-width column',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: SizedBox(
                width: 342,
                child: ReplyQuote(
                  resolved: message(
                    id: 'parent',
                    authorDisplayName:
                        'Christoph Bartholomew Fitzgerald-Huang III',
                    content: 'short reply',
                  ),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a quoted webhook keeps its badge, even with its claimed name at '
      'phone width', (tester) async {
    late BatchProfilesController controller;
    final longClaim = 'Definitely A Real Person ' * 8;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          batchProfilesControllerProvider.overrideWith((ref) {
            controller = BatchProfilesController(ref);
            return controller;
          }),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: ReplyQuote(
                resolved: message(
                  id: 'parent',
                  authorId: 'webhook-1',
                  authorDisplayName: longClaim,
                  content: 'the disk is nearly full',
                ),
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    controller.state = {
      'webhook-1': api.UserProfile(
        id: 'webhook-1',
        username: 'alerts',
        displayName: longClaim,
        createdAt: 0,
        isWebhook: true,
      ),
    };
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.text('WEBHOOK'),
      findsOneWidget,
      reason:
          'docs/decisions/0030 calls this badge the entire mitigation for '
          "a webhook's claimed name; a reply quote is the surface this "
          'card names first',
    );
    expect(tester.getRect(find.byType(AppBadge)).width, greaterThan(0));
  });

  testWidgets('tapping the quote calls onTap, resolved or not', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      harness(ReplyQuote(resolved: null, onTap: () => tapped++)),
    );
    await tester.tap(find.byType(ReplyQuote));
    expect(
      tapped,
      1,
      reason: 'a jump can still succeed further back in history',
    );
  });

  testWidgets(
    'a focused quote draws the design system\'s own focus ring, not the '
    'Material default overlay',
    (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );

      await tester.pumpWidget(
        harness(ReplyQuote(resolved: null, onTap: () {})),
      );

      expect(_hasQuoteFocusRing(tester), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(
        _hasQuoteFocusRing(tester),
        isTrue,
        reason:
            'InkWell draws Material\'s own translucent focus overlay by '
            'default; AppFocusRing is what replaces it with this design '
            'language\'s own outline token',
      );
    },
  );
}

/// Mirrors `context_menu_reachability_test.dart`'s own `_hasFocusRing`
/// helper, adapted for [AppFocusRing]'s `Container`-based ring rather than a
/// `foregroundDecoration` one.
bool _hasQuoteFocusRing(WidgetTester tester) => tester.any(
  find.byWidgetPredicate((w) {
    if (w is! Container) return false;
    final decoration = w.decoration;
    return decoration is BoxDecoration &&
        decoration.border?.top.color == AppTokens.light.focusRing;
  }),
);

void _noop() {}
