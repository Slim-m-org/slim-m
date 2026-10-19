// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_token_prefetch.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_prefetch_region.dart';

void main() {
  late List<String> fetched;

  setUp(() => fetched = []);

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceTokenPrefetchProvider.overrideWithValue(
          VoiceTokenPrefetch((channelId) async {
            fetched.add(channelId);
            throw StateError('unused');
          }),
        ),
      ],
      child: const MaterialApp(
        home: Center(
          child: VoicePrefetchRegion(
            channelId: 'lounge',
            child: SizedBox(width: 200, height: 40, child: Text('lounge')),
          ),
        ),
      ),
    ),
  );

  Future<TestGesture> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('lounge')));
    return mouse;
  }

  testWidgets('a pointer that rests on the row warms the token', (
    tester,
  ) async {
    await pump(tester);
    await hover(tester);

    await tester.pump(kVoicePrefetchDwell + const Duration(milliseconds: 10));

    expect(fetched, ['lounge']);
  });

  testWidgets('a pointer sweeping across the row warms nothing', (
    tester,
  ) async {
    await pump(tester);
    final mouse = await hover(tester);

    await tester.pump(kVoicePrefetchDwell - const Duration(milliseconds: 50));
    await mouse.moveTo(Offset.zero);
    await tester.pump(kVoicePrefetchDwell * 2);

    expect(fetched, isEmpty);
  });

  testWidgets('a finger landing on the row warms the token at once', (
    tester,
  ) async {
    await pump(tester);

    final touch = await tester.startGesture(
      tester.getCenter(find.text('lounge')),
    );
    await touch.up();

    expect(fetched, ['lounge']);
  });

  testWidgets('focus reaching the row warms the token', (tester) async {
    await pump(tester);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceTokenPrefetchProvider.overrideWithValue(
            VoiceTokenPrefetch((channelId) async {
              fetched.add(channelId);
              throw StateError('unused');
            }),
          ),
        ],
        child: MaterialApp(
          home: VoicePrefetchRegion(
            channelId: 'lounge',
            child: Focus(focusNode: focus, child: const Text('lounge')),
          ),
        ),
      ),
    );

    focus.requestFocus();
    await tester.pump();

    expect(fetched, ['lounge']);
  });
}
