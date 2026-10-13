// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join gate's wire types: the `join_gate.changed` frame and the two
/// bodies the gate's routes exchange.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('join_gate.changed carries the member who accepted, or nobody', () {
    final accepted = ServerEvent.parse(
      jsonEncode({'type': 'join_gate.changed', 'user_id': 'user-1'}),
    );
    expect((accepted as JoinGateChanged).userId, 'user-1');
    final settings = ServerEvent.parse(
      jsonEncode({'type': 'join_gate.changed', 'user_id': null}),
    );
    expect((settings as JoinGateChanged).userId, isNull);
    final bare = ServerEvent.parse(jsonEncode({'type': 'join_gate.changed'}));
    expect((bare as JoinGateChanged).userId, isNull);
  });

  test('a malformed join_gate.changed is ignored, not thrown', () {
    final event = ServerEvent.parse(
      jsonEncode({'type': 'join_gate.changed', 'user_id': 7}),
    );
    expect(event, isNull);
  });

  test('the gate round-trips and a missing field reads as off', () {
    const gate = JoinGate(
      enabled: true,
      rules: 'be kind',
      rulesChannelId: 'c-1',
      joinsPaused: false,
    );
    final back = JoinGate.fromJson(gate.toJson());
    expect(back.enabled, isTrue);
    expect(back.rules, 'be kind');
    expect(back.rulesChannelId, 'c-1');
    expect(back.joinsPaused, isFalse);
    final empty = JoinGate.fromJson(const {});
    expect(empty.enabled || empty.joinsPaused, isFalse);
  });

  test('rules read pending, and default to not pending', () {
    expect(
      SpaceRules.fromJson(const {'rules': 'x', 'pending': true}).pending,
      isTrue,
    );
    expect(SpaceRules.fromJson(const {}).pending, isFalse);
  });
}
