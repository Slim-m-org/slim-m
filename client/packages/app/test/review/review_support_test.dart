// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The review gallery's naming rule: every PNG name parses back into surface,
/// state, viewport and theme, so the gallery can group them by regex alone.
library;

import 'package:flutter_test/flutter_test.dart';

import 'review_support.dart';

final _gallery = RegExp(
  r'^(?<surface>[a-z0-9]+(?:-[a-z0-9]+)*)'
  r'(?:--(?<state>[a-z0-9]+(?:-[a-z0-9]+)*))?'
  r'--(?<viewport>phone|desktop)-(?<theme>dark|light)$',
);

void main() {
  test('a resting surface leaves the state out', () {
    expect(
      reviewName('app-not-found', null, 'desktop', 'dark'),
      'app-not-found--desktop-dark',
    );
  });

  test('a state goes between the surface and the viewport', () {
    expect(
      reviewName('sheet-reset-password', 'code-rejected', 'phone', 'light'),
      'sheet-reset-password--code-rejected--phone-light',
    );
  });

  test('every name the gallery regex groups is one reviewName writes', () {
    final match = _gallery.firstMatch(
      reviewName('auth-sign-in', 'rate-limited', 'phone', 'dark'),
    )!;
    expect(match.namedGroup('surface'), 'auth-sign-in');
    expect(match.namedGroup('state'), 'rate-limited');
    expect(match.namedGroup('viewport'), 'phone');
    expect(match.namedGroup('theme'), 'dark');
  });

  test('a double hyphen inside a part is refused', () {
    expect(
      () => reviewName('auth--sign-in', null, 'phone', 'dark'),
      throwsArgumentError,
    );
    expect(
      () => reviewName('auth-sign-in', 'wrong--credentials', 'phone', 'dark'),
      throwsArgumentError,
    );
  });

  test('capitals, underscores and edge hyphens are refused', () {
    for (final bad in ['Auth-sign-in', 'auth_sign_in', '-auth', 'auth-', '']) {
      expect(
        () => reviewName(bad, null, 'phone', 'dark'),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(
      () => reviewName('auth-sign-in', 'Wrong', 'phone', 'dark'),
      throwsArgumentError,
    );
  });

  test('only the two review viewports and plain theme words are accepted', () {
    expect(
      () => reviewName('auth-sign-in', null, 'tablet', 'dark'),
      throwsArgumentError,
    );
    expect(
      () => reviewName('auth-sign-in', null, 'phone-portrait', 'dark'),
      throwsArgumentError,
    );
    expect(
      () => reviewName('auth-sign-in', null, 'phone', 'Dark'),
      throwsArgumentError,
    );
  });

  test('the viewports map to the harness sizes', () {
    expect(reviewViewports, {
      'phone': 'phone-portrait',
      'desktop': 'review-desktop',
    });
  });
}
