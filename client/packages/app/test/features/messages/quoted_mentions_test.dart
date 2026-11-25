// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mentions inside the two surfaces that show another message's text: the
/// thread parent card and the reply quote.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_quote.dart';
import 'package:slimm_app/src/features/messages/widgets/thread_parent_card.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _nick = api.UserProfile(
  id: 'u-nick',
  username: 'nc1107',
  displayName: 'Nick',
  createdAt: 0,
  roles: ['Mods'],
);

const _text = 'ping @nc1107 and @[Mods] and @everyone about this';

List<Override> _roster() => [
  membersProvider.overrideWith((ref) async => const [_nick]),
];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

List<String> _boldRuns(WidgetTester tester) {
  final runs = <String>[];
  void walk(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.style?.fontWeight == AppWeights.semi) {
      runs.add(span.toPlainText());
    }
    span.children?.forEach(walk);
  }

  for (final rich in tester.widgetList<RichText>(
    find.byWidgetPredicate((w) => w is RichText),
  )) {
    walk(rich.text);
  }
  return runs;
}

void main() {
  testWidgets('a thread parent shows resolved names for every mention kind', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        const ThreadParentCard(
          parent: api.ThreadParent(
            parentChannelId: 'c0',
            parentMessageId: 'm0',
            parentContent: _text,
            parentAuthorId: 'u-nick',
            parentAuthorDisplayName: 'Nick',
          ),
          threadChannelId: 'c1',
        ),
        overrides: _roster(),
      ),
    );
    await _settle(tester);

    expect(find.textContaining('Nick', findRichText: true), findsWidgets);
    expect(find.textContaining('@nc1107', findRichText: true), findsNothing);
    // The chip names the account in its tooltip, which plain text never does.
    expect(find.byTooltip('@nc1107'), findsOneWidget);
    expect(find.textContaining('@Mods', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('@everyone', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('@[Mods]', findRichText: true), findsNothing);
  });

  testWidgets('a thread parent renders inline formatting, not its markers', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        const ThreadParentCard(
          parent: api.ThreadParent(
            parentChannelId: 'c0',
            parentMessageId: 'm0',
            parentContent: 'a **bold** claim',
            parentAuthorId: 'u-nick',
            parentAuthorDisplayName: 'Nick',
          ),
          threadChannelId: 'c1',
        ),
        overrides: _roster(),
      ),
    );
    await _settle(tester);

    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('bold', findRichText: true), findsOneWidget);
    expect(_boldRuns(tester), contains('bold'));
  });

  testWidgets('a reply quote shows the mentioned member\'s name, one line', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 360,
          child: ReplyQuote(
            resolved: message(id: 'parent', content: _text),
            onTap: () {},
          ),
        ),
        overrides: _roster(),
      ),
    );
    await _settle(tester);

    expect(find.textContaining('@Nick'), findsOneWidget);
    expect(find.textContaining('@nc1107'), findsNothing);
    expect(find.textContaining('@everyone'), findsOneWidget);
    expect(find.textContaining('@Mods'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(ReplyQuote.quoteKey)).height,
      ReplyQuote.heightOf(tester.element(find.byKey(ReplyQuote.quoteKey))),
    );
  });
}
