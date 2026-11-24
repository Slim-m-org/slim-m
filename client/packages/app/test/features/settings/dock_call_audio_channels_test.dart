// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the call-audio channel toggle says when the change does not go through.
library;

import 'dart:convert';

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

  test('two quick changes both reach the server', () async {
    var held = <String>['a'];
    final puts = <List<String>>[];
    final container = _container((request) async {
      if (request.method == 'GET') {
        return jsonHttpResponse({'channel_ids': held});
      }
      final sent = [
        for (final id in (jsonDecode(request.body)['channel_ids'] as List))
          '$id',
      ];
      puts.add(sent);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      held = sent;
      return jsonHttpResponse({'channel_ids': held});
    });
    final provider = dockCallAudioChannelsProvider('transcript');
    container.listen(provider, (_, _) {});
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    final first = notifier.toggle('a', armed: false);
    final second = notifier.toggle('b', armed: true);
    expect(container.read(provider).requireValue.saving, isTrue);
    await Future.wait([first, second]);

    expect(held, ['b']);
    expect(puts, [
      <String>[],
      ['b'],
    ]);
    expect(container.read(provider).requireValue.ids, ['b']);
    expect(container.read(provider).requireValue.saving, isFalse);
  });

  test('a change after the list rebuilt still finishes saving', () async {
    final container = _container((request) async {
      if (request.method == 'GET') {
        return jsonHttpResponse({'channel_ids': <String>[]});
      }
      return jsonHttpResponse({
        'channel_ids': ['voice-1'],
      });
    });
    final provider = dockCallAudioChannelsProvider('transcript');
    container.listen(provider, (_, _) {});
    await container.read(provider.future);
    container.invalidate(provider);
    await container.read(provider.future);

    await container.read(provider.notifier).toggle('voice-1', armed: true);

    final held = container.read(provider).requireValue;
    expect(held.saving, isFalse);
    expect(held.ids, ['voice-1']);
  });
}
