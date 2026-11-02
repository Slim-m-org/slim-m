// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wire for a module hearing a call as text (decision 0104): the state,
/// the `voice.call_audio` frame, the four call routes and the channel list.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _session({
  String status = 'asking',
  List<String> included = const ['u1'],
  List<String> pending = const ['u2', 'u3'],
}) =>
    {
      'module_id': 'transcript',
      'module_name': 'Transcript',
      'purpose': 'Writes down what is said.',
      'keeps': 'The text, for 30 days.',
      'status': status,
      'asked_by': 'u1',
      'included': included,
      'pending': pending,
      'expires_at_ms': 1700000060000,
      'full': false,
    };

SlimmApi _api(
  Future<http.Response> Function(http.Request request) handler,
) =>
    SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

void main() {
  test('a session parses who said yes and who has not answered', () {
    final state = CallAudioState.fromJson(_session());
    expect(state.isOn, isFalse);
    expect(state.isIncluded('u1'), isTrue);
    expect(state.isAsking('u2'), isTrue);
    expect(state.isAsking('u1'), isFalse);
    expect((state.answered, state.total), (1, 3));
    expect(state.purpose, 'Writes down what is said.');
    expect(CallAudioState.fromJson(_session(status: 'on')).isOn, isTrue);
  });

  test('voice.call_audio carries the state, or null and how it ended', () {
    final on = ServerEvent.parse(jsonEncode({
      'type': 'voice.call_audio',
      'channel_id': 'c1',
      'state': _session(status: 'on'),
    }))! as VoiceCallAudioChanged;
    expect(on.channelId, 'c1');
    expect(on.state!.isOn, isTrue);
    expect(on.ended, isNull);

    final ended = ServerEvent.parse(jsonEncode({
      'type': 'voice.call_audio',
      'channel_id': 'c1',
      'state': null,
      'ended': 'lapsed',
    }))! as VoiceCallAudioChanged;
    expect(ended.state, isNull);
    expect(ended.ended, 'lapsed');
  });

  test('a voice.call_audio frame with no channel is ignored', () {
    expect(
      ServerEvent.parse(
          jsonEncode({'type': 'voice.call_audio', 'state': null})),
      isNull,
    );
  });

  test('the status route parses the session and the startable modules',
      () async {
    final api = _api((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/channels/c1/voice/call-audio');
      return http.Response(
        jsonEncode({
          'session': null,
          'startable': [
            {
              'module_id': 'transcript',
              'module_name': 'Transcript',
              'purpose': 'p',
              'keeps': 'k',
            },
          ],
        }),
        200,
      );
    });
    final status = await api.callAudio('c1');
    expect(status.session, isNull);
    expect(status.startable.single.moduleId, 'transcript');
  });

  test('asking, answering and stopping use their routes', () async {
    final seen = <String>[];
    final api = _api((request) async {
      seen.add('${request.method} ${request.url.path} ${request.body}');
      if (request.method == 'DELETE') return http.Response('', 204);
      return http.Response(
        jsonEncode({'session': _session(), 'startable': <Object>[]}),
        200,
      );
    });
    final asked = await api.requestCallAudio('c1', 'transcript');
    expect(asked.session!.moduleName, 'Transcript');
    await api.answerCallAudio('c1', allow: false);
    await api.stopCallAudio('c1');
    expect(seen, [
      'POST /channels/c1/voice/call-audio {"module_id":"transcript"}',
      'PUT /channels/c1/voice/call-audio/consent {"allow":false}',
      'DELETE /channels/c1/voice/call-audio ',
    ]);
  });

  test('the channel list reads and replaces', () async {
    final bodies = <String>[];
    final api = _api((request) async {
      bodies.add('${request.method} ${request.url.path} ${request.body}');
      return http.Response(
        jsonEncode({
          'channel_ids': ['c1', 'c2']
        }),
        200,
      );
    });
    expect(await api.callAudioChannels('transcript'), ['c1', 'c2']);
    expect(await api.setCallAudioChannels('transcript', ['c2']), ['c1', 'c2']);
    expect(bodies, [
      'GET /space/dock/modules/transcript/call-audio-channels ',
      'PUT /space/dock/modules/transcript/call-audio-channels {"channel_ids":["c2"]}',
    ]);
  });

  test('a manifest carries the module call_audio words when it declares them',
      () {
    final base = {
      'id': 'transcript',
      'name': 'Transcript',
      'version': '0.1.0',
      'summary': 's',
      'artifact': {'kind': 'wasm', 'path': 'a.wasm', 'sha256': 'a'},
      'runtime': {'backend': 'wasm', 'limits': <String, Object>{}},
      'permissions': <Object>[],
      'capabilities': ['call.audio'],
      'extension_points': <Object>[],
    };
    expect(DockManifest.fromJson(base).callAudio, isNull);
    final with_ = DockManifest.fromJson({
      ...base,
      'call_audio': {'purpose': 'p', 'keeps': 'k', 'permission': 'start'},
    });
    expect(with_.callAudio!.purpose, 'p');
    expect(with_.callAudio!.permission, 'start');
  });
}
