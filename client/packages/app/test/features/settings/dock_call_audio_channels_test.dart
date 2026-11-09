// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the call-audio channel toggle says when the change does not go through.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/features/settings/providers/dock_call_audio_channels.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

ProviderContainer _container(MockClientHandler handler) {
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWith((ref) {
        final api = testApi(handler);
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'a dropped connection is told in words, not as the request log',
    () async {
      final container = _container((request) async {
        if (request.method == 'GET') {
          return jsonHttpResponse({'channel_ids': <String>[]});
        }
        throw http.ClientException('socket closed', request.url);
      });
      final provider = dockCallAudioChannelsProvider('transcript');
      container.listen(provider, (_, _) {});
      await container.read(provider.future);

      await container.read(provider.notifier).toggle('voice-1', armed: true);

      expect(
        container.read(provider).requireValue.error,
        'Could not change the calls it can hear: the server could not be '
        'reached. Nothing was changed.',
      );
    },
  );

  test('a refusal keeps the server reason after the shared opening', () async {
    final container = _container((request) async {
      if (request.method == 'GET') {
        return jsonHttpResponse({'channel_ids': <String>[]});
      }
      return jsonHttpResponse({'error': 'call audio is not approved'}, 409);
    });
    final provider = dockCallAudioChannelsProvider('transcript');
    container.listen(provider, (_, _) {});
    await container.read(provider.future);

    await container.read(provider.notifier).toggle('voice-1', armed: true);

    expect(
      container.read(provider).requireValue.error,
      'Could not change the calls it can hear. Call audio is not approved.',
    );
  });
}
