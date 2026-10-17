// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The continuation marker (none, clean, tree) asserted as painted geometry on
/// a real transcript: where the rail sits, where it joins and where it stops.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/settings/providers/display_density.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/continuation_marker.dart';
import 'package:slimm_app/src/features/settings/widgets/display_density_preview.dart';
import 'package:slimm_app/src/features/settings/widgets/display_settings_section.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'message_row_harness.dart';
import '../../ui_snapshot_support.dart';
import '../../support/fake_sync.dart';

const _longBody =
    'the resync path replays every op after the last seen seq, so a client '
    'that was offline for an hour sends one request and applies the tail '
    'strictly in order and then keeps going for a good while longer';

const _base = 1700000000000;

Message _msg(
  String id,
  int n,
  String author, {
  String? content,
  bool pending = false,
}) => message(
  id: id,
  authorId: author,
  authorDisplayName: author,
  createdAt: _base + n * 1000,
  content: content ?? 'body $id',
  pending: pending,
);

List<Message> _conversation({bool pendingLast = false}) => [
  _msg('m1', 1, 'ada'),
  _msg('m2', 2, 'ada', content: _longBody),
  _msg('m3', 3, 'ada'),
  _msg('n1', 4, 'bob'),
  _msg('n2', 5, 'bob', pending: pendingLast),
];

ProviderContainer _container(ContinuationMarker marker) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: const TokenPair(
            userId: 'self',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(
            (_) async => http.Response(
              jsonEncode([]),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        ref.onDispose(api.close);
        return api;
      }),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
    ],
  );
  addTearDown(container.dispose);
  container.read(continuationMarkerControllerProvider.notifier).select(marker);
  return container;
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  ContinuationMarker marker, {
  double width = 900,
  bool pendingLast = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = _container(marker);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: RepaintBoundary(
            key: snapshotBoundary,
            child: MessageTranscript(
              channelId: 'c1',
              messages: _conversation(pendingLast: pendingLast),
              syncStatus: SyncStatus.live,
              historyKnown: true,
              channelName: 'general',
              scrollController: ScrollController(),
              lastReadSeq: 999999,
              selfId: 'self',
              knownUsernames: const {},
              customEmoji: const {},
              history: const ChannelHistory(atStart: true),
              onLoadOlder: () {},
              onRetryOlder: () {},
              actionsFor: (_, _) => noActions,
              onRetry: (_) {},
              onDiscard: (_) {},
              onPickReaction: (_, _) {},
              onReactionTap: (_, _) {},
              onVote: (_, _) {},
              onSubmitEdit: (_, _) {},
              onCancelEdit: () {},
              onJumpToReply: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

Finder _row(String id) => find.descendant(
  of: find.byKey(ValueKey(id)),
  matching: find.byType(MessageRow),
);

Finder _rail(String id) => find.descendant(
  of: find.byKey(ValueKey(id)),
  matching: find.byKey(ContinuationRail.railKey),
);

Rect _rowRect(WidgetTester t, String id) => t.getRect(_row(id));

Rect _railRect(WidgetTester t, String id) => t.getRect(_rail(id));

double get _midline =>
    AppDensity.normal.groupedRowGap +
    AppText.body.fontSize! * AppText.body.height! / 2;

double _avatarCentre(WidgetTester t) => t
    .getRect(
      find.descendant(
        of: find.byKey(const ValueKey('m1')),
        matching: find.byType(AppAvatar),
      ),
    )
    .center
    .dx;

double _textLeft(WidgetTester t, String id) => t
    .getRect(
      find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.byType(MessageBody),
      ),
    )
    .left;

void main() {
  for (final marker in [ContinuationMarker.clean, ContinuationMarker.tree]) {
    for (final (name, width) in [('phone', 390.0), ('desktop', 1000.0)]) {
      testWidgets('renders a picture, ${marker.name} at $name width', (
        tester,
      ) async {
        await _pump(tester, marker, width: width);
        await writeSnapshot(tester, 'continuation-${marker.name}-$name');
      });
    }
  }

  for (final width in [900.0, 390.0]) {
    group('clean at ${width.toInt()} wide', () {
      testWidgets('the rail is centred on the avatar column, not on headers', (
        tester,
      ) async {
        await _pump(tester, ContinuationMarker.clean, width: width);
        final centre = _avatarCentre(tester);
        for (final id in ['m2', 'm3', 'n2']) {
          final rail = _railRect(tester, id);
          expect(rail.center.dx, closeTo(centre, 0.01), reason: id);
          expect(rail.width, 2);
        }
        expect(_rail('m1'), findsNothing);
        expect(_rail('n1'), findsNothing);
      });

      testWidgets('it runs unbroken through a row and stops at the midline', (
        tester,
      ) async {
        await _pump(tester, ContinuationMarker.clean, width: width);
        final m2 = _railRect(tester, 'm2');
        final m3 = _railRect(tester, 'm3');
        expect(m2.top, _rowRect(tester, 'm2').top);
        expect(m2.bottom, _rowRect(tester, 'm2').bottom);
        expect(m3.top, m2.bottom, reason: 'no gap between continuation rows');
        expect(m3.top, _rowRect(tester, 'm3').top);
        expect(m3.bottom, closeTo(m3.top + _midline, 0.01));
        expect(m2.height, greaterThan(40), reason: 'the long row wrapped');
      });

      testWidgets('two groups never join', (tester) async {
        await _pump(tester, ContinuationMarker.clean, width: width);
        expect(
          _railRect(tester, 'm3').bottom,
          lessThan(_railRect(tester, 'n2').top),
        );
      });

      testWidgets('the last rail ends in a rounded cap', (tester) async {
        await _pump(tester, ContinuationMarker.clean, width: width);
        const tokens = AppTokens.dark;
        final last = tester.renderObject(_rail('m3'));
        expect(
          last,
          paints..rrect(
            rrect: RRect.fromLTRBAndCorners(
              0,
              0,
              2,
              _midline,
              bottomLeft: const Radius.circular(1),
              bottomRight: const Radius.circular(1),
            ),
            color: tokens.borderSubtle,
          ),
        );
        final mid = tester.renderObject(_rail('m2'));
        expect(
          mid,
          paints..rrect(
            rrect: RRect.fromLTRBAndCorners(
              0,
              0,
              2,
              _rowRect(tester, 'm2').height,
            ),
          ),
        );
      });
    });
  }

  group('tree', () {
    testWidgets('every continuation gets an elbow that stops short of text', (
      tester,
    ) async {
      await _pump(tester, ContinuationMarker.tree);
      final centre = _avatarCentre(tester);
      for (final id in ['m2', 'm3', 'n2']) {
        final rail = _railRect(tester, id);
        expect(rail.left + 1, closeTo(centre, 0.01), reason: id);
        expect(
          _textLeft(tester, id) - rail.right,
          ContinuationRail.textGap,
          reason: '$id elbow tip to text',
        );
      }
      expect(_rail('m1'), findsNothing);
    });

    testWidgets('the rail continues below a middle elbow, not a last one', (
      tester,
    ) async {
      await _pump(tester, ContinuationMarker.tree);
      final m2 = _railRect(tester, 'm2');
      final m3 = _railRect(tester, 'm3');
      expect(m2.bottom, _rowRect(tester, 'm2').bottom);
      expect(m3.top, m2.bottom);
      expect(m3.bottom, closeTo(m3.top + _midline + 1, 0.01));
    });

    testWidgets('the elbow is stroked in the border token', (tester) async {
      await _pump(tester, ContinuationMarker.tree);
      expect(
        tester.renderObject(_rail('m3')),
        paints..path(color: AppTokens.dark.borderSubtle),
      );
    });
  });

  testWidgets('none paints no marker at all', (tester) async {
    await _pump(tester, ContinuationMarker.none);
    expect(find.byKey(ContinuationRail.railKey), findsNothing);
  });

  group('hover time', () {
    final timeText = formatMessageTime(_base + 3000, use24Hour: false);
    final time = find.descendant(
      of: find.byKey(const ValueKey('m3')),
      matching: find.text(timeText),
    );

    Future<TestGesture> hover(WidgetTester tester, String id) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(_rowRect(tester, id).center);
      await tester.pumpAndSettle();
      return gesture;
    }

    testWidgets('none keeps it in the gutter', (tester) async {
      await _pump(tester, ContinuationMarker.none);
      expect(time, findsNothing);
      await hover(tester, 'm3');
      final mark = tester.getRect(time);
      expect(mark.left, lessThan(_textLeft(tester, 'm3') - 10));
    });

    for (final marker in [ContinuationMarker.clean, ContinuationMarker.tree]) {
      testWidgets('${marker.name} moves it after the text, without a reflow', (
        tester,
      ) async {
        await _pump(tester, marker);
        final before = tester.getRect(
          find.descendant(
            of: find.byKey(const ValueKey('m3')),
            matching: find.byType(MessageBody),
          ),
        );
        await hover(tester, 'm3');
        final body = tester.getRect(
          find.descendant(
            of: find.byKey(const ValueKey('m3')),
            matching: find.byType(MessageBody),
          ),
        );
        expect(body, before);
        final mark = tester.getRect(time);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.textContaining('body m3', findRichText: true),
        );
        final end = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 7),
            )
            .last
            .toRect()
            .shift(paragraph.localToGlobal(Offset.zero));
        expect(mark.left, greaterThan(end.right));
        expect(mark.left - end.right, lessThan(16));
        expect((mark.center.dy - end.center.dy).abs(), lessThan(4));
        final opacity = tester.widget<Opacity>(
          find.ancestor(of: time, matching: find.byType(Opacity)).first,
        );
        expect(opacity.opacity, 1);
      });
    }

    testWidgets('it is invisible until hovered', (tester) async {
      await _pump(tester, ContinuationMarker.clean);
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: time, matching: find.byType(Opacity)).first,
      );
      expect(opacity.opacity, 0);
    });
  });

  testWidgets('a pending mark sits on the rail with a backing', (tester) async {
    await _pump(tester, ContinuationMarker.clean, pendingLast: true);
    final icon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('n2')),
        matching: find.byIcon(AppIcons.clock),
      ),
    );
    expect(icon.center.dx, closeTo(_railRect(tester, 'n2').center.dx, 0.01));
    final backing = find.descendant(
      of: find.byKey(const ValueKey('n2')),
      matching: find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == AppTokens.dark.surfaceBase,
      ),
    );
    expect(backing, findsOneWidget);
  });

  group('preference', () {
    testWidgets('survives a restart and falls back to none', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final first = _container(ContinuationMarker.none);
      expect(
        first.read(continuationMarkerControllerProvider),
        ContinuationMarker.none,
      );
      await first
          .read(continuationMarkerControllerProvider.notifier)
          .select(ContinuationMarker.tree);
      final second = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
      );
      addTearDown(second.dispose);
      await second
          .read(continuationMarkerControllerProvider.notifier)
          .restore();
      expect(
        second.read(continuationMarkerControllerProvider),
        ContinuationMarker.tree,
      );
    });

    testWidgets('the settings row switches it and the preview follows', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final container = _container(ContinuationMarker.none);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: ListView(children: const [DisplaySettingsSection()]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Thread lines'), findsOneWidget);
      expect(find.byKey(ContinuationRail.railKey), findsNothing);

      await tester.tap(find.text('Tree'));
      await tester.pumpAndSettle();

      expect(
        container.read(continuationMarkerControllerProvider),
        ContinuationMarker.tree,
      );
      expect(
        find.descendant(
          of: find.byKey(DisplayDensityPreview.continuationRowKey),
          matching: find.byKey(ContinuationRail.railKey),
        ),
        findsOneWidget,
      );
    });
  });
}
