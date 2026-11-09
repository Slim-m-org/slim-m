// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone sheet clips what it holds to its rounded top corners, and a sheet
/// that opens on a picture can take its handle over it.
///
/// Material clips nothing by default, so a full-width banner kept square
/// corners that poked past the sheet's curve.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _red = Color(0xFFD62828);
const _bodyKey = Key('edge-body');
final _boundary = GlobalKey();

Future<void> _open(WidgetTester tester, {required bool handleOver}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppSheet<void>(
                context,
                handleOverContent: handleOver,
                builder: (_) => const SizedBox(
                  key: _bodyKey,
                  height: 120,
                  child: ColoredBox(color: _red),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<Color Function(double x, double y)> _pixels(WidgetTester tester) async {
  late ui.Image image;
  late ByteData bytes;
  await tester.runAsync(() async {
    final render =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    image = await render.toImage();
    bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });
  return (double x, double y) {
    final i = (y.round() * image.width + x.round()) * 4;
    return Color.fromARGB(
      bytes.getUint8(i + 3),
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
    );
  };
}

void main() {
  testWidgets('content that runs to the top edge follows the rounded corners', (
    tester,
  ) async {
    await _open(tester, handleOver: true);
    final sheet = tester.getRect(find.byType(BottomSheet));
    final pixel = await _pixels(tester);

    expect(pixel(sheet.center.dx - 80, sheet.top + 2), _red);
    expect(pixel(sheet.left + 1, sheet.top + 2), isNot(_red));
    expect(pixel(sheet.right - 2, sheet.top + 2), isNot(_red));
  });

  testWidgets('every phone sheet clips to its corners, handle strip or not', (
    tester,
  ) async {
    await _open(tester, handleOver: false);
    final body = tester.getRect(find.byKey(_bodyKey));
    final pixel = await _pixels(tester);

    // The body's own top corners sit outside a 28 radius arc.
    expect(pixel(body.left + 1, body.top + 2), isNot(_red));
    expect(pixel(body.right - 2, body.top + 2), isNot(_red));
    expect(pixel(body.center.dx, body.top + 2), _red);
  });

  testWidgets('a handle over the content takes no room of its own', (
    tester,
  ) async {
    await _open(tester, handleOver: true);
    final sheet = tester.getRect(find.byType(BottomSheet));

    expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, sheet.top);
    expect(sheet.height, 120);
  });

  testWidgets('the handle strip is still reserved by default', (tester) async {
    await _open(tester, handleOver: false);
    final sheet = tester.getRect(find.byType(BottomSheet));

    expect(
      tester.getTopLeft(find.byKey(_bodyKey)).dy,
      sheet.top + kSheetHandleExtent,
    );
  });

  testWidgets('tapping the handle over the content closes the sheet', (
    tester,
  ) async {
    await _open(tester, handleOver: true);
    final sheet = tester.getRect(find.byType(BottomSheet));

    await tester.tapAt(Offset(sheet.center.dx, sheet.top + 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(_bodyKey), findsNothing);
  });

  testWidgets('a tap beside the handle reaches the content under it', (
    tester,
  ) async {
    await _open(tester, handleOver: true);
    final sheet = tester.getRect(find.byType(BottomSheet));

    await tester.tapAt(Offset(sheet.left + 40, sheet.top + 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(_bodyKey), findsOneWidget);
  });
}
