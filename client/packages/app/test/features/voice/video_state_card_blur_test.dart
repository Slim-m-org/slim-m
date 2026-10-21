// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A paused or loading share card sits over the share's blurred last frame, not a flat surface.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/video_state_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

Future<ui.Image> _image() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(List.filled(64, 120)),
    4,
    4,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

Widget _card(ScreenShareStatus status) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox(
        width: 360,
        height: 200,
        child: Builder(
          builder: (context) => screenShareStatusCard(
            context: context,
            status: status,
            identity: 'sharer',
            name: 'Sam',
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a paused share shows its last frame blurred; an ended one does '
      'not', (tester) async {
    final image = (await tester.runAsync(_image))!;
    LastFrameStore.instance.put('screen:sharer', image);
    addTearDown(LastFrameStore.instance.clear);

    await tester.pumpWidget(_card(ScreenShareStatus.paused));
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.text('Share paused'), findsOneWidget);

    await tester.pumpWidget(_card(ScreenShareStatus.ended));
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('without a remembered frame the card is flat as before', (
    tester,
  ) async {
    await tester.pumpWidget(_card(ScreenShareStatus.loading));
    expect(find.byType(ImageFiltered), findsNothing);
  });
}
