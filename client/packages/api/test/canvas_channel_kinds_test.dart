// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas kind and its two toggles: wire parsing, the getter table, bodies.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _json(
  String kind, {
  bool? canvas,
  bool? voice,
  String? parent,
}) =>
    {
      'id': 'c1',
      'name': 'n',
      'kind': kind,
      'created_at': 1,
      if (canvas != null) 'canvas_enabled': canvas,
      if (voice != null) 'voice_enabled': voice,
      if (parent != null) 'parent_message_id': parent,
    };

Channel _channel(String kind, {bool? canvas, bool? voice, String? parent}) =>
    Channel.fromJson(_json(kind, canvas: canvas, voice: voice, parent: parent));

SlimmApi _api(void Function(String method, Map<String, dynamic>? body) seen) =>
    SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        seen(
          request.method,
          request.body.isEmpty
              ? null
              : jsonDecode(request.body) as Map<String, dynamic>,
        );
        return http.Response(jsonEncode(_json('canvas', canvas: true)), 200);
      }),
    );

void main() {
  group('Channel flags and getters', () {
    test('absent flags parse as null', () {
      final c = _channel('voice');
      expect(c.canvasEnabled, isNull);
      expect(c.voiceEnabled, isNull);
    });

    test('present flags parse', () {
      final c = _channel('canvas', canvas: true, voice: false);
      expect(c.canvasEnabled, isTrue);
      expect(c.voiceEnabled, isFalse);
    });

    test('the getter table', () {
      // kind, canvas, voice -> isCanvasChannel, hasCanvas, hostsCall
      final rows = <(Channel, bool, bool, bool)>[
        (_channel('text'), false, false, false),
        (_channel('voice'), false, true, true),
        (_channel('voice', canvas: true, voice: true), false, true, true),
        (_channel('voice', canvas: false, voice: true), false, false, true),
        (_channel('canvas', canvas: true, voice: true), true, true, true),
        (_channel('canvas', canvas: true, voice: false), true, true, false),
        (_channel('canvas'), true, true, false),
        (_channel('dm'), false, true, false),
        (_channel('dm', canvas: true, voice: true), false, true, false),
        (_channel('voice', parent: 'm1'), false, false, false),
        (
          _channel('voice', canvas: true, voice: true, parent: 'm1'),
          false,
          false,
          false
        ),
      ];
      for (final (c, isCanvas, hasCanvas, hostsCall) in rows) {
        final label = '${c.kind} ${c.canvasEnabled} ${c.voiceEnabled}';
        expect(c.isCanvasChannel, isCanvas, reason: label);
        expect(c.hasCanvas, hasCanvas, reason: label);
        expect(c.hostsCall, hostsCall, reason: label);
      }
    });

    test('a canvas channel is never voice by kind', () {
      expect(_channel('canvas', voice: true).isVoice, isFalse);
    });
  });

  group('RolePreviewChannel flags', () {
    RolePreviewChannel preview(String kind, {bool? canvas, bool? voice}) =>
        RolePreviewChannel.fromJson({
          'id': 'c',
          'name': 'n',
          'kind': kind,
          'position': 0,
          'permissions': 0,
          'restricted': false,
          if (canvas != null) 'canvas_enabled': canvas,
          if (voice != null) 'voice_enabled': voice,
        });

    test('absent flags fall back to the old rule', () {
      expect(preview('voice').hasCanvas, isTrue);
      expect(preview('voice').hostsCall, isTrue);
      expect(preview('text').hasCanvas, isFalse);
      expect(preview('text').hostsCall, isFalse);
      expect(preview('canvas').isCanvasChannel, isTrue);
      expect(preview('canvas').hostsCall, isFalse);
    });

    test('present flags win', () {
      final c = preview('voice', canvas: false, voice: true);
      expect(c.hasCanvas, isFalse);
      expect(c.hostsCall, isTrue);
      expect(preview('canvas', canvas: true, voice: true).hostsCall, isTrue);
    });
  });

  group('/version', () {
    Version version(Map<String, Object?> extra) => Version.fromJson({
          'name': 'slim-m',
          'version': '0.1.0',
          'protocol': 1,
          ...extra,
        });

    test('canvas_channels and the two capabilities', () {
      final on = version({
        'canvas_channels': true,
        'capabilities': ['canvas_viewers', 'canvas_export'],
      });
      expect(on.canvasChannels, isTrue);
      expect(on.supportsCanvasViewers, isTrue);
      expect(on.supportsCanvasExport, isTrue);
      final off = version({});
      expect(off.canvasChannels, isFalse);
      expect(off.supportsCanvasViewers, isFalse);
      expect(off.supportsCanvasExport, isFalse);
    });
  });

  group('bodies', () {
    test('create sends the canvas kind and the flags only when given',
        () async {
      Map<String, dynamic>? body;
      final api = _api((_, b) => body = b);
      await api.createChannel(name: 'a', kind: 'canvas', voiceEnabled: true);
      expect(body, {'name': 'a', 'kind': 'canvas', 'voice_enabled': true});
      await api.createChannel(name: 'v', kind: 'voice', canvasEnabled: false);
      expect(body, {'name': 'v', 'kind': 'voice', 'canvas_enabled': false});
      await api.createChannel(name: 't');
      expect(body, {'name': 't', 'kind': 'text'});
    });

    test('update carries both flags and discard_canvas', () async {
      Map<String, dynamic>? body;
      final api = _api((_, b) => body = b);
      await api.updateChannel(
        'c1',
        const ChannelUpdate(canvasEnabled: false, discardCanvas: true),
      );
      expect(body, {'canvas_enabled': false, 'discard_canvas': true});
      await api.updateChannel('c1', const ChannelUpdate(voiceEnabled: true));
      expect(body, {'voice_enabled': true});
      await api.updateChannel('c1', const ChannelUpdate(name: 'x'));
      expect(body, {'name': 'x'});
    });
  });

  test('canvas_off is a named forbidden code', () {
    expect(ForbiddenException.canvasOffCode, 'canvas_off');
  });
}
