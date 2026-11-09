// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A slash command that finishes after the person started the next message must not wipe it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_slash.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _roll = api.SlashCommand(
  moduleId: 'dice',
  command: 'roll',
  name: 'roll',
  description: 'Roll',
);

/// Runs `/roll 20` against an api that answers only once [gate] completes.
Future<TextEditingController> _startRoll(Completer<void> gate) async {
  final controller = TextEditingController(text: '/roll 20');
  addTearDown(controller.dispose);
  final client = testApi((request) async {
    await gate.future;
    return http.Response(
      jsonEncode({'ok': true, 'message_id': 'm1'}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  unawaited(
    sendSlashCommand(
      api: client,
      command: _roll,
      args: '20',
      channelId: 'c1',
      controller: controller,
      isMounted: () => true,
      onPosted: () {},
      fail: (_) {},
    ),
  );
  return controller;
}

Future<void> _finish(Completer<void> gate) async {
  gate.complete();
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  test('what was typed while the command ran survives it', () async {
    final gate = Completer<void>();
    final controller = await _startRoll(gate);

    controller.text = '/roll 20 and then some';
    await _finish(gate);

    expect(controller.text, ' and then some');
  });

  test('a field rewritten while the command ran is left alone', () async {
    final gate = Completer<void>();
    final controller = await _startRoll(gate);

    controller.text = 'something else entirely';
    await _finish(gate);

    expect(controller.text, 'something else entirely');
  });

  test('an untouched field is cleared when the command finishes', () async {
    final gate = Completer<void>();
    final controller = await _startRoll(gate);

    await _finish(gate);

    expect(controller.text, isEmpty);
  });
}
