// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip under a share keeps its overflow findable: a bar that stays,
/// drag and wheel that move it, and a chip for a speaker scrolled out of view.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart'
    show speakingIdentitiesProvider;
import 'package:slimm_app/src/features/voice/widgets/call_filmstrip.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

VoiceParticipant _p(int i, {bool speaking = false}) => VoiceParticipant(
  identity: 'p$i',
  name: 'p$i',
  isSpeaking: speaking,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

Future<void> _pump(
  WidgetTester tester, {
  required int people,
  int? speaker,
  double width = 600,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        speakingIdentitiesProvider.overrideWithValue({
          if (speaker != null) 'p$speaker',
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  width: width,
                  height: 128,
                  child: CallFilmstrip(
                    key: _stripKey,
                    leading: const [],
                    leadingItemWidth: 199,
                    participants: [
                      for (var i = 0; i < people; i++)
                        _p(i, speaking: i == speaker),
                    ],
                    tileBuilder: (context, p) => SizedBox(
                      key: ValueKey('tile-${p.identity}'),
                      width: kCallTileMinWidth,
                      height: 90,
                    ),
                  ),
                ),
                const SizedBox(key: _pageMarkerKey, height: 2000),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  _pageStart = tester.getTopLeft(find.byKey(_pageMarkerKey)).dy;
}

const _stripKey = ValueKey('strip');
const _pageMarkerKey = ValueKey('page-marker');

// The first tile's left edge moves left by exactly how far the strip scrolled.
double _stripOffset(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_stripKey)).dx -
    tester.getTopLeft(find.byKey(const ValueKey('tile-p0'))).dx;

// The marker below the strip moves up by how far the page scrolled.
double _pageOffset(WidgetTester tester) =>
    _pageStart - tester.getTopLeft(find.byKey(_pageMarkerKey)).dy;

late double _pageStart;

Finder get _chip => find.byKey(moreSpeakingChipKey);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('hiddenSpeakers', () {
    final widths = List.filled(6, 144.0);

    test('counts a speaker wholly past either edge', () {
      final speaking = [true, false, false, false, false, true];
      final unscrolled = hiddenSpeakers(
        offset: 0,
        viewport: 500,
        widths: widths,
        speaking: speaking,
      );
      expect(unscrolled, (before: 0, after: 1));
      final scrolled = hiddenSpeakers(
        offset: 400,
        viewport: 500,
        widths: widths,
        speaking: speaking,
      );
      expect(scrolled, (before: 1, after: 0));
    });

    test('a speaker partly in view is not hidden', () {
      final speaking = [false, false, false, false, true, false];
      final partly = hiddenSpeakers(
        offset: 0,
        viewport: 650,
        widths: widths,
        speaking: speaking,
      );
      expect(partly, (before: 0, after: 0));
    });
  });

  testWidgets('the bar stays up only while the strip overflows', (
    tester,
  ) async {
    await _pump(tester, people: 8);
    expect(
      tester
          .widget<Scrollbar>(find.byKey(filmstripScrollbarKey))
          .thumbVisibility,
      isTrue,
    );

    await _pump(tester, people: 3);
    expect(
      tester
          .widget<Scrollbar>(find.byKey(filmstripScrollbarKey))
          .thumbVisibility,
      isFalse,
    );
  });

  testWidgets('a mouse drag scrolls the strip', (tester) async {
    await _pump(tester, people: 8);
    const tile = ValueKey('tile-p3');
    final before = tester.getTopLeft(find.byKey(tile)).dx;
    final mouse = await tester.startGesture(
      const Offset(300, 60),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-120, 0));
    await mouse.moveBy(const Offset(-120, 0));
    await mouse.up();
    await tester.pump();
    expect(before - tester.getTopLeft(find.byKey(tile)).dx, greaterThan(100));
  });

  testWidgets('a plain wheel scrolls the strip and not the page', (
    tester,
  ) async {
    await _pump(tester, people: 8);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(300, 60)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(_stripOffset(tester), 120);
    expect(_pageOffset(tester), 0);
  });

  testWidgets('a wheel over a strip that fits still scrolls the page', (
    tester,
  ) async {
    await _pump(tester, people: 3);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(300, 60)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(_pageOffset(tester), 120);
  });

  group('the chip for a speaker out of view', () {
    testWidgets('names the speaker and the strip does not chase them', (
      tester,
    ) async {
      await _pump(tester, people: 8, speaker: 7);
      expect(_chip, findsOneWidget);
      expect(find.text('1 more'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('1 more speaking')), findsOneWidget);
      expect(_stripOffset(tester), 0);
    });

    testWidgets('is absent when the speaker is on screen', (tester) async {
      await _pump(tester, people: 8, speaker: 1);
      expect(_chip, findsNothing);
    });

    testWidgets('is absent when nothing overflows', (tester) async {
      await _pump(tester, people: 3, speaker: 2);
      expect(_chip, findsNothing);
    });

    testWidgets('tapping it brings the speaker into view and drops the chip', (
      tester,
    ) async {
      await _pump(tester, people: 8, speaker: 7);
      await tester.tap(_chip);
      await _settle(tester);
      final tile = tester.getRect(find.byKey(const ValueKey('tile-p7')));
      expect(tile.right, lessThanOrEqualTo(600));
      expect(_chip, findsNothing);
    });

    testWidgets(
      'shows on the left once the speaker has scrolled off that edge',
      (tester) async {
        await _pump(tester, people: 8, speaker: 0);
        expect(_chip, findsNothing);
        final mouse = await tester.startGesture(
          const Offset(300, 60),
          kind: PointerDeviceKind.mouse,
        );
        for (var i = 0; i < 6; i++) {
          await mouse.moveBy(const Offset(-120, 0));
        }
        await mouse.up();
        await _settle(tester);
        expect(_chip, findsOneWidget);
        expect(tester.getCenter(_chip).dx, lessThan(300));
      },
    );
  });
}
