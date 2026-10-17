// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `devicePlatformLabel`/`deviceDetailLine`: naming a device by platform
/// rather than the raw registration string, and the client/version/last-
/// active line that replaces the old "Signed in" fallback. See
/// `devices_section.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/devices_section.dart';

api.Device _device({
  String name = 'Linux (fedora)',
  String? clientKind,
  String? clientVersion,
  int? lastSeenAt,
}) => api.Device(
  id: 'd1',
  name: name,
  createdAt: 0,
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
      expect(line, 'desktop 0.83.0 · active now');
    });

    test('still renders with only one of client kind or version present', () {
      final line = deviceDetailLine(
        _device(
          clientKind: 'ios',
          lastSeenAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      expect(line, 'ios · active now');
    });
  });
}
