// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:math' as math;

import 'package:slimm_design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Text a person is meant to read: body, secondary and the placeholder the
/// theme resolves for an input, on every surface, in every theme. The
/// disabled token is exempt (WCAG 1.4.3) and is deliberately not listed.
void main() {
  final themes = {
    'light': (Brightness.light, AppTokens.light),
    'dark': (Brightness.dark, AppTokens.dark),
    'trueBlack': (Brightness.dark, AppTokens.trueBlack),
    'mocha': (Brightness.dark, AppTokens.mocha),
  };

  themes.forEach((name, entry) {
    final (brightness, tokens) = entry;
    final theme = buildTheme(brightness, tokens);
    final placeholder = theme.inputDecorationTheme.hintStyle!.color!;
    final roles = {
      'body': tokens.textPrimary,
      'secondary': tokens.textSecondary,
      'placeholder': placeholder,
    };
    final surfaces = {
      'sunken': tokens.surfaceSunken,
      'base': tokens.surfaceBase,
      'raised': tokens.surfaceRaised,
    };
    roles.forEach((role, color) {
      surfaces.forEach((surface, bg) {
        test('$name $role text on $surface is at least 4.5:1', () {
          expect(
            _contrast(color, bg),
            greaterThanOrEqualTo(4.5),
            reason: '$name $role on $surface',
          );
        });
      });
    });
  });
}
