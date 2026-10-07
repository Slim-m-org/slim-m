// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mini player's corner maths: where each corner puts the card and where a
/// drag or a flick lands it. Split from call_mini_player_test.dart for its size.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/call_mini_player.dart';

void main() {
  group('geometry', () {
    const region = Size(400, 700);
    const card = Size(192, 150);
    const insets = MiniPlayerInsets(top: 12, bottom: 104);

    test('a flick throws the card past the nearest corner', () {
      final origin = cornerOrigin(
        MiniPlayerCorner.bottomRight,
        region,
        card,
        insets,
      );
      final landed = nearestCorner(
        origin - const Offset(60, 60),
        const Offset(-2500, -2500),
        region,
        card,
        insets,
      );
      expect(landed, MiniPlayerCorner.topLeft);
    });

    test('a slow drag lands on the closest corner', () {
      final landed = nearestCorner(
        const Offset(60, 200),
        Offset.zero,
        region,
        card,
        insets,
      );
      expect(landed, MiniPlayerCorner.topLeft);
    });
  });
}
