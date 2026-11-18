// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `devicePlatformLabel`/`deviceDetailLine`: naming a device by platform
/// rather than the raw registration string, and the client/version/last-
/// active line that replaces the old "Signed in" fallback. See
/// `devices_section.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/widgets/devices_section.dart';

api.Device _device({
  String name = 'Linux (fedora)',
  String? clientKind,
  String? clientVersion,
  int? lastSeenAt,
  int? createdAt,
}) => api.Device(
  id: 'd1',
  name: name,
  createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch,
  lastSeenAt: lastSeenAt,
  isCurrent: false,
  clientKind: clientKind,
  clientVersion: clientVersion,
);

void main() {
  group('devicePlatformLabel', () {
    test('reads an older parenthesised name the way new builds send it', () {
      expect(devicePlatformLabel('Linux (fedora)'), 'Linux - fedora');
      expect(devicePlatformLabel('Linux - fedora'), 'Linux - fedora');
    });

    test('drops the loopback host name an iPhone used to report', () {
      expect(devicePlatformLabel('iOS (localhost)'), 'iOS');
    });

    test('passes a name with no parenthetical through unchanged', () {
      expect(devicePlatformLabel('desktop'), 'desktop');
      expect(devicePlatformLabel('A phone'), 'A phone');
    });
  });

  group('deviceDetailLine', () {
    test('is null when the server carries no client kind or version', () {
      expect(deviceDetailLine(_device()), isNull);
    });

    test('joins client, version and last active when both are known', () {
      final line = deviceDetailLine(
        _device(
          clientKind: 'desktop',
          clientVersion: '0.83.0',
          lastSeenAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      expect(
        line?.replaceAll('\u00A0', ' '),
        'desktop 0.83.0 · active now · signed in just now',
      );
    });

    test('still renders with only one of client kind or version present', () {
      final line = deviceDetailLine(
        _device(
          clientKind: 'ios',
          lastSeenAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      expect(
        line?.replaceAll('\u00A0', ' '),
        'ios · active now · signed in just now',
      );
    });

    test('says when each session signed in, so two alike can be told '
        'apart', () {
      final now = DateTime.now();
      final line = deviceDetailLine(
        _device(
          clientKind: 'web',
          clientVersion: '0.131.0',
          lastSeenAt: now.millisecondsSinceEpoch,
          createdAt: now
              .subtract(const Duration(days: 3))
              .millisecondsSinceEpoch,
        ),
      );
      expect(
        line?.replaceAll('\u00A0', ' '),
        'web 0.131.0 · active now · signed in 3d ago',
      );
    });
  });
}
