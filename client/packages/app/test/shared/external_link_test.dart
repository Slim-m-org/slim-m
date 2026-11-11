// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/external_link.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  Future<List<Uri>> opened(String raw) async {
    final calls = <Uri>[];
    await openExternalHttpUrl(
      raw,
      launcher: (url, {mode = LaunchMode.platformDefault}) async {
        expect(mode, LaunchMode.externalApplication);
        calls.add(url);
        return true;
      },
    );
    return calls;
  }

  for (final raw in [
    'http://example.com/a',
    'https://example.com/a?b=1',
    'HTTPS://example.com',
  ]) {
    test('$raw opens in the system browser', () async {
      expect(await opened(raw), hasLength(1));
    });
  }

  for (final raw in [
    'javascript:alert(1)',
    'file:///etc/passwd',
    'intent://scan/#Intent;scheme=zxing;end',
    'mailto:a@example.com',
    'slimm://message?server=x',
    'example.com/no-scheme',
    '',
    'http://[bad',
  ]) {
    test('"$raw" is never handed to the launcher', () async {
      expect(await opened(raw), isEmpty);
    });
  }

  group('openSteamGame', () {
    Future<List<Uri>> run(int appId) async {
      final calls = <Uri>[];
      await openSteamGame(
        appId,
        launcher: (url, {mode = LaunchMode.platformDefault}) async {
          expect(mode, LaunchMode.externalApplication);
          calls.add(url);
          return true;
        },
      );
      return calls;
    }

    test('opens steam://run with the id', () async {
      expect((await run(730)).single.toString(), 'steam://run/730');
    });

    test('a non-positive id launches nothing', () async {
      expect(await run(0), isEmpty);
      expect(await run(-5), isEmpty);
    });
  });
}
