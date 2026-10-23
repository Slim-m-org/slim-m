// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for channel creation, rename/topic updates, and deletion: the
/// `channels` tag beyond [SlimmApi.listChannels].
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Uri get _base => Uri.parse('http://localhost:8080');

TokenPair _tokens() => const TokenPair(
      userId: 'user-1',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      accessExpiresAt: 0,
    );

Map<String, dynamic> _channelJson({
  String id = 'chan-1',
  String name = 'general',
  String kind = 'text',
  String? topic,
  int slowModeSeconds = 0,
  bool joinMuted = false,
  String? defaultNotification,
}) =>
    {
      'id': id,
      'name': name,
      'kind': kind,
      'topic': topic,
      'created_at': 1,
      'slow_mode_seconds': slowModeSeconds,
      'join_muted': joinMuted,
      if (defaultNotification != null)
        'default_notification': defaultNotification,
    };

void main() {
  group('createChannel', () {
    test('sends the chosen kind and parses the created channel', () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(_channelJson(name: 'lounge', kind: 'voice')),
            200,
          );
        }),
      );
      final created = await api.createChannel(name: 'lounge', kind: 'voice');
      expect(sentBody, {'name': 'lounge', 'kind': 'voice'});
      expect(created.name, 'lounge');
      expect(created.isVoice, isTrue);
    });

    test('sends the client id when one is given', () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode(_channelJson(name: 'lounge')), 200);
        }),
      );
      await api.createChannel(name: 'lounge', id: 'id-1');
      expect(sentBody, containsPair('id', 'id-1'));
    });
    test('a non-default notification level is sent, the default is not',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode(_channelJson()), 200);
        }),
      );
      await api.createChannel(name: 'a');
      await api.createChannel(
        name: 'b',
        defaultNotification: NotificationPreference.mentions,
      );
      expect(bodies[0], {'name': 'a', 'kind': 'text'});
      expect(bodies[1]['default_notification'], 'mentions');
    });
  });

  group('updateChannel', () {
    test('a name-only rename omits topic from the request body', () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode(_channelJson(name: 'renamed')), 200);
        }),
      );
      final updated = await api.updateChannel(
          'chan-1', const ChannelUpdate(name: 'renamed'));
      expect(sentBody, {'name': 'renamed'});
      expect(updated.name, 'renamed');
    });

    test(
        'a blank topic still round-trips: the server, not this client, '
        'is what treats it as clearing the topic', () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode(_channelJson()), 200);
        }),
      );
      await api.updateChannel(
          'chan-1', const ChannelUpdate(name: 'general', topic: ''));
      expect(sentBody, {'name': 'general', 'topic': ''});
    });

    test('a topic update carries both fields when both are given', () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(_channelJson(topic: 'announcements only')),
            200,
          );
        }),
      );
      final updated = await api.updateChannel('chan-1',
          const ChannelUpdate(name: 'general', topic: 'announcements only'));
      expect(sentBody, {'name': 'general', 'topic': 'announcements only'});
      expect(updated.topic, 'announcements only');
    });

    test('a slow-mode-only update omits name and topic and round-trips',
        () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(_channelJson(slowModeSeconds: 30)),
            200,
          );
        }),
      );
      final updated = await api.updateChannel(
          'chan-1', const ChannelUpdate(slowModeSeconds: 30));
      expect(sentBody, {'slow_mode_seconds': 30});
      expect(updated.slowModeSeconds, 30);
    });

    test('a join-muted-only update sends just that field and round-trips',
        () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(_channelJson(kind: 'voice', joinMuted: true)),
            200,
          );
        }),
      );
      final updated = await api.updateChannel(
          'chan-1', const ChannelUpdate(joinMuted: true));
      expect(sentBody, {'join_muted': true});
      expect(updated.joinMuted, isTrue);
    });
    test('a default-notification update sends just that field and round-trips',
        () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(_channelJson(defaultNotification: 'nothing')),
            200,
          );
        }),
      );
      final updated = await api.updateChannel(
          'chan-1',
          const ChannelUpdate(
              defaultNotification: NotificationPreference.nothing));
      expect(sentBody, {'default_notification': 'nothing'});
      expect(updated.defaultNotification, NotificationPreference.nothing);
    });

    test('a channel from an older server reads as having no default', () {
      expect(
        Channel.fromJson(_channelJson()).defaultNotification,
        NotificationPreference.everything,
      );
    });
  });

  group('deleteChannel', () {
    test('a 204 completes with no error', () async {
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((_) async => http.Response('', 204)),
      );
      await api.deleteChannel('chan-1');
    });

    test('the last-channel refusal surfaces as a ConflictException', () async {
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((_) async => http.Response(
              jsonEncode(
                  {'error': 'cannot delete the deployment\'s last channel'}),
              409,
            )),
      );
      await expectLater(
        () => api.deleteChannel('chan-1'),
        throwsA(isA<ConflictException>()),
      );
    });
  });

  group('getChannelPermissions', () {
    test('requests the channel-scoped route and unwraps the bitmask', () async {
      String? requestedPath;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          requestedPath = request.url.path;
          return http.Response(jsonEncode({'permissions': 42}), 200);
        }),
      );
      final permissions = await api.getChannelPermissions('chan-1');
      expect(requestedPath, '/channels/chan-1/permissions');
      expect(permissions, 42);
    });
  });
}
