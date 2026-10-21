// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A child laid flush against an [AppMenu]'s top edge, like a profile banner,
/// stays inside the menu's rounded corners.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _band = Color(0xFF00FF00);

void main() {
  testWidgets('a flush top band does not paint past the rounded corner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: RepaintBoundary(
              key: boundary,
              child: AppMenu(
                width: 200,
                padding: EdgeInsets.zero,
                floating: false,
                children: [Container(height: 40, color: _band)],
              ),
            ),
          ),
        ),
      ),
    );

    final pixels = await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (data!, image.width);
    });
    final (data, width) = pixels!;
    Color at(int x, int y) {
      final i = (y * width + x) * 4;
      return Color.fromARGB(
        data.getUint8(i + 3),
        data.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
      );
    }

    expect(at(1, 1), isNot(_band), reason: 'the top-left corner is rounded');
    expect(at(width - 2, 1), isNot(_band), reason: 'and the top-right');
    expect(at(width ~/ 2, 20), _band, reason: 'the band still fills its row');
  });
}
