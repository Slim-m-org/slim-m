// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opt-in gating as a viewer sees it: nothing is offered until the sharer says
/// so, and a sharer who goes quiet stops being believed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_consent.dart';

final _t0 = DateTime(2026, 10, 28, 12);

api.CanvasScreenAnnotation _consent({
  String from = 'sharer',
  String about = 'sharer',
  bool allowed = true,
  double? aspect = 1.7778,
}) => api.CanvasScreenAnnotation(
  channelId: 'c',
  userId: from,
  targetUserId: about,
  kind: 'consent',
  points: const [],
  ended: false,
  allowed: allowed,
  aspect: aspect,
);

void main() {
  test('nobody is allowed by default', () {
    expect(ScreenAnnotationConsent().of('sharer', _t0), isNull);
  });

  test('a sharer who allows drawing is believed, with their screen shape', () {
    final consent = ScreenAnnotationConsent()..apply(_consent(), _t0);
    expect(consent.of('sharer', _t0)!.aspect, 1.7778);
  });

  test('consent spoken by someone else for the sharer is ignored', () {
    final consent = ScreenAnnotationConsent()
      ..apply(_consent(from: 'viewer'), _t0);
    expect(consent.of('sharer', _t0), isNull);
  });

  test('turning it off is believed at once', () {
    final consent = ScreenAnnotationConsent()
      ..apply(_consent(), _t0)
      ..apply(_consent(allowed: false), _t0);
    expect(consent.of('sharer', _t0), isNull);
  });

  test('a sharer who stops repeating consent stops being believed', () {
    final consent = ScreenAnnotationConsent()..apply(_consent(), _t0);
    expect(consent.of('sharer', _t0.add(consentLifetime)), isNotNull);
    expect(
      consent.of(
        'sharer',
        _t0.add(consentLifetime + const Duration(seconds: 1)),
      ),
      isNull,
    );
  });

  test('the heartbeat is well inside the lifetime', () {
    expect(consentHeartbeat * 2, lessThan(consentLifetime));
  });
}
