// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Module settings parsing and the four module slot and settings calls.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

SlimmApi _api(Future<http.Response> Function(http.Request) handler) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

void main() {
  group('settings parsing', () {
    test('each type, default, range and choice is read', () {
      final doc = ModuleSettingsDoc.fromJson({
        'settings': [
          {
            'key': 'xp',
            'type': 'int',
            'label': 'XP',
            'help': 'Per minute.',
            'default': 5,
            'min': 0,
            'max': 100,
            'value': 7,
          },
          {'key': 'on', 'type': 'bool', 'label': 'On', 'value': true},
          {
            'key': 'mode',
            'type': 'choice',
            'label': 'Mode',
            'choices': [
              {'value': 'a', 'label': 'A'},
              {'value': 'b'},
              'junk',
            ],
            'value': 'a',
          },
          {'key': 'name', 'type': 'string', 'label': 'Name'},
        ],
      });
      final xp = doc.settings[0];
      expect(xp.def.type, ModuleSettingType.integer);
      expect([xp.def.min, xp.def.max, xp.def.defaultValue, xp.value],
          [0, 100, 5, 7]);
      expect(xp.def.help, 'Per minute.');
      expect(doc.settings[1].value, true);
      final mode = doc.settings[2].def;
      expect(mode.choices.map((c) => c.label), ['A', 'b']);
      expect(doc.settings[3].value, isNull);
    });

    test('an unknown type parses as unknown instead of throwing', () {
      final doc = ModuleSettingsDoc.fromJson({
        'settings': [
          {'key': 'k', 'type': 'color', 'label': 'K', 'value': 'red'},
        ],
      });
      expect(doc.settings.single.def.type, ModuleSettingType.unknown);
    });

    test('a secret reports only whether it is set', () {
      final doc = ModuleSettingsDoc.fromJson({
        'settings': [
          {
            'key': 'a',
            'type': 'secret',
            'label': 'A',
            'value': {'set': true},
          },
          {
            'key': 'b',
            'type': 'secret',
            'label': 'B',
            'value': {'set': false},
          },
          {'key': 'c', 'type': 'secret', 'label': 'C'},
        ],
      });
      expect(doc.settings.map((e) => e.secretSet), [true, false, false]);
      expect(doc.settings.map((e) => e.value), everyElement(isNull));
    });

    test('malformed input yields fewer settings, never an error', () {
      expect(ModuleSettingsDoc.fromJson(null).settings, isEmpty);
      expect(ModuleSettingsDoc.fromJson({'settings': 3}).settings, isEmpty);
      final doc = ModuleSettingsDoc.fromJson({
        'settings': [
          null,
          {'type': 'int'},
          {'key': 'ok', 'type': 'int', 'min': 'x'},
        ],
      });
      expect(doc.settings.single.def.key, 'ok');
      expect(doc.settings.single.def.min, isNull);
      expect(doc.settings.single.def.label, 'ok');
    });
  });

  group('settings calls', () {
    test('moduleSettings GETs the module settings path', () async {
      late http.Request seen;
      final api = _api((r) async {
        seen = r;
        return _json({
          'settings': [
            {'key': 'k', 'type': 'bool', 'label': 'K', 'value': false},
          ],
        });
      });
      final doc = await api.moduleSettings('xp');
      expect([seen.method, seen.url.path],
          ['GET', '/space/dock/modules/xp/settings']);
      expect(doc.settings.single.value, false);
    });

    test('saveModuleSettings PUTs values, keeping a null to clear', () async {
      late http.Request seen;
      final api = _api((r) async {
        seen = r;
        return _json({'settings': <Object>[]});
      });
      await api.saveModuleSettings('xp', {'a': 1, 'b': null});
      expect([seen.method, seen.url.path],
          ['PUT', '/space/dock/modules/xp/settings']);
      expect(jsonDecode(seen.body), {
        'values': {'a': 1, 'b': null},
      });
    });
  });

  group('slot calls', () {
    test('moduleProfileSlots GETs the member path and parses sections',
        () async {
      late http.Request seen;
      final api = _api((r) async {
        seen = r;
        return _json({
          'sections': [
            {
              'module_id': 'xp',
              'name': 'level',
              'title': 'Level',
              'nodes': [
                {'type': 'text', 'text': '4'},
              ],
            },
            'junk',
          ],
        });
      });
      final sections = await api.moduleProfileSlots('user-9');
      expect(seen.url.path, '/space/dock/slots/profile/user-9');
      expect(sections.single.title, 'Level');
      expect(sections.single.item.nodes, hasLength(1));
    });

    test('moduleBadges sends a comma-joined ids query and parses the map',
        () async {
      late Uri seen;
      final api = _api((r) async {
        seen = r.url;
        return _json({
          'badges': {
            'a': [
              {'module_id': 'xp', 'name': 'lvl', 'fallback': '4'},
            ],
            'b': <Object>[],
          },
        });
      });
      final result = await api.moduleBadges(['a', 'b']);
      expect(seen.path, '/space/dock/slots/badges');
      expect(seen.queryParameters['ids'], 'a,b');
      expect(result.keys, ['a']);
      expect(result['a']!.single.item.fallback, '4');
    });

    test('more than 100 ids are split into requests of at most 100', () async {
      final queries = <String>[];
      final api = _api((r) async {
        final ids = r.url.queryParameters['ids']!.split(',');
        queries.add(ids.length.toString());
        return _json({
          'badges': {
            ids.first: [
              {'module_id': 'm', 'name': 'n'},
            ],
          },
        });
      });
      final ids = List.generate(250, (i) => 'u$i');
      final result = await api.moduleBadges(ids);
      expect(queries, ['100', '100', '50']);
      expect(result.keys, ['u0', 'u100', 'u200']);
    });

    test('an empty list makes no request', () async {
      var calls = 0;
      final api = _api((r) async {
        calls++;
        return _json({'badges': <String, Object>{}});
      });
      expect(await api.moduleBadges(const []), isEmpty);
      expect(calls, 0);
    });
  });
}
