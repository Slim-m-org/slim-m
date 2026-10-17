// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Gates the keys SlimmApi sends against schema/openapi.yaml.
///
/// `schema_coverage_test.dart` proves every documented route has a client
/// call; this proves each call sends only body keys and query parameters the
/// spec declares for that route and method. Reproduced before it existed:
/// renaming `'max_height'` to `'maxheight'` in `setSpaceScreenShareMaxHeight`
/// passed the whole api suite and would 400 against a real server.
///
/// The client side is read from source (see `support/send_calls.dart`); the
/// spec side is parsed YAML with `$ref` and `allOf` resolved.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'support/send_calls.dart';

/// Call sites whose keys cannot be read from source, by `METHOD /path`.
const Map<String, String> _unreadableKeys = {};

/// Body or query keys the client sends that the spec does not declare, by
/// `METHOD /path key`. Each is a deliberate exception with its reason.
const Map<String, String> _allowedUndeclared = {
  'GET /reports after_id': 'the server requires `after_id` with `after` '
      '(crates/slimm-server/src/http/reports.rs) but the spec omits it; the '
      'spec needs the parameter added, which is a schema change outside '
      'this gate',
};

/// Which class declares the `toJson()` passed as the body at each route.
const ToJsonOwners _toJsonOwners = {
  'PUT /space/join-gate': 'JoinGate',
  'PUT /presence/activity': 'PresenceActivity',
};

void main() {
  final root = _repoRoot();
  final spec =
      loadYaml(File('${root.path}/schema/openapi.yaml').readAsStringSync())
          as YamlMap;
  final calls = extractSendCalls(
    Directory('${root.path}/client/packages/api/lib/src'),
    _toJsonOwners,
  );
  final ops = _operations(spec);

  test('both extractors find something', () {
    expect(calls.length, greaterThan(100));
    expect(ops, isNotEmpty);
  });

  test('every client call sends only keys the spec declares', () {
    final problems = <String>[];
    for (final call in calls) {
      final op = ops[call.key];
      if (op == null) continue;
      _check(call, op, problems);
    }
    problems.sort();
    expect(problems, isEmpty, reason: '\n${problems.join('\n')}\n');
  });

  test('the exception lists name only live entries', () {
    final keys = calls.map((c) => c.key).toSet();
    for (final k in _unreadableKeys.keys) {
      expect(keys, contains(k), reason: '$k is listed but never called');
    }
    final undeclared = <String>{};
    for (final call in calls) {
      final op = ops[call.key];
      if (op == null) continue;
      final problems = <String>[];
      _check(call, op, problems, ignoreAllowlist: true);
      undeclared.addAll(problems.map((p) => p.split(' | ').first));
    }
    for (final k in _allowedUndeclared.keys) {
      expect(undeclared, contains(k), reason: '$k is allowed but not needed');
    }
  });
}

void _check(
  SendCall call,
  _Operation op,
  List<String> problems, {
  bool ignoreAllowlist = false,
}) {
  void flag(String kind, String key) {
    final id = '${call.key} $key';
    if (!ignoreAllowlist && _allowedUndeclared.containsKey(id)) return;
    problems.add('$id | ${call.where} sends $kind `$key` the spec does not '
        'declare');
  }

  if (call.hasQuery) {
    final keys = call.queryKeys;
    if (keys == null) {
      if (!_unreadableKeys.containsKey(call.key) || ignoreAllowlist) {
        problems.add('${call.key} query | ${call.where} query keys cannot be '
            'read from source');
      }
    } else {
      keys.where((k) => !op.query.contains(k)).forEach((k) => flag('query', k));
    }
  }
  if (call.hasBody) {
    final keys = call.bodyKeys;
    if (keys == null) {
      if (!_unreadableKeys.containsKey(call.key) || ignoreAllowlist) {
        problems.add('${call.key} body | ${call.where} body keys cannot be '
            'read from source');
      }
    } else if (!op.freeformBody) {
      keys.where((k) => !op.body.contains(k)).forEach((k) => flag('body', k));
    }
  }
}

class _Operation {
  _Operation(this.query, this.body, this.freeformBody);

  final Set<String> query;
  final Set<String> body;
  final bool freeformBody;
}

Map<String, _Operation> _operations(YamlMap spec) {
  Object? deref(Object? node) {
    var n = node;
    while (n is YamlMap && n['\$ref'] is String) {
      var cur = spec as Object?;
      for (final part in (n['\$ref'] as String).substring(2).split('/')) {
        cur = (cur as YamlMap)[part];
      }
      n = cur;
    }
    return n;
  }

  // Null means the schema takes arbitrary keys.
  Set<String>? properties(Object? schema) {
    final s = deref(schema);
    if (s is! YamlMap) return null;
    final out = <String>{};
    final props = s['properties'];
    if (props is YamlMap) out.addAll(props.keys.cast<String>());
    for (final branch in [
      ...?s['allOf'] as List?,
      ...?s['oneOf'] as List?,
      ...?s['anyOf'] as List?,
    ]) {
      final sub = properties(branch);
      if (sub == null) return null;
      out.addAll(sub);
    }
    if (out.isEmpty || s['additionalProperties'] == true) return null;
    return out;
  }

  final ops = <String, _Operation>{};
  final paths = spec['paths'] as YamlMap;
  for (final entry in paths.entries) {
    final item = entry.value as YamlMap;
    final shared = [...?item['parameters'] as List?];
    for (final method in const ['get', 'post', 'put', 'patch', 'delete']) {
      final op = item[method];
      if (op is! YamlMap) continue;
      final query = <String>{};
      for (final p in [...shared, ...?op['parameters'] as List?]) {
        final param = deref(p) as YamlMap;
        if (param['in'] == 'query') query.add(param['name'] as String);
      }
      final content = (deref(op['requestBody']) as YamlMap?)?['content'];
      final json = content is YamlMap
          ? content.entries
              .where((e) => (e.key as String).contains('json'))
              .map((e) => (e.value as YamlMap)['schema'])
              .firstOrNull
          : null;
      final body = json == null ? null : properties(json);
      final path = _normalize(entry.key as String);
      ops['${method.toUpperCase()} $path'] =
          _Operation(query, body ?? {}, json != null && body == null);
    }
  }
  return ops;
}

String _normalize(String path) => path
    .split('/')
    .map((s) => s.startsWith('{') && s.endsWith('}') ? '{}' : s)
    .join('/');

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/schema/openapi.yaml').existsSync()) return dir;
    dir = dir.parent;
  }
  fail('could not find schema/openapi.yaml above ${Directory.current.path}');
}
