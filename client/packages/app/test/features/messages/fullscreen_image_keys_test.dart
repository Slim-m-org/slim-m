// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fullscreen viewer's keyboard: arrows page and Escape closes, even when
/// keyboard focus is not on the viewer. On web the browser hands focus to the
/// semantics layer after the route opens, so a handler that only lives on the
/// viewer's own focus node never saw a key.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_design_system/design_system.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkA'
  'AAgEsAtmMCMaywi+hcEKLNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE'
  'BAQEBAQEBAQEBAQEBAQEBAQELguFPsFaQDQP9QAAAABJRU5ErkJggg==',
);

final _images = [
  for (var i = 1; i <= 3; i++)
    api.Attachment(
      id: 'a$i',
      filename: 'img$i.png',
      contentType: 'image/png',
      size: 2048,
    ),
];

/// A page with a focused text field, the composer the viewer opens over.
Future<FocusNode> _openViewer(
  WidgetTester tester, {
  int index = 1,
  bool reduceMotion = false,
}) async {
  final composer = FocusNode();
  addTearDown(composer.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        attachmentBytesProvider.overrideWith((ref, id) async => _png),
      ],
      child: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextField(focusNode: composer),
                  TextButton(
                    onPressed: () => showFullscreenImage(
                      context,
                      images: _images,
                      index: index,
                      bytes: _png,
                    ),
                    child: const Text('open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  composer.requestFocus();
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('${index + 1} of 3'), findsOneWidget);
  return composer;
}

void main() {
  testWidgets('Escape closes the viewer', (tester) async {
    await _openViewer(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenImageViewer), findsNothing);
  });

  testWidgets('the arrows page while focus sits on the page behind', (
    tester,
  ) async {
    final composer = await _openViewer(tester);
    composer.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('3 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
  });

  testWidgets('Escape closes it from the page behind as well', (tester) async {
    final composer = await _openViewer(tester);
    composer.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenImageViewer), findsNothing);
  });

  testWidgets('the arrows page when motion is reduced, as with a screen '
      'reader on', (tester) async {
    await _openViewer(tester, reduceMotion: true);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('3 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
  });
}
