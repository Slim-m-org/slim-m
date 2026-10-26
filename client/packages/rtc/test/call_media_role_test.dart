// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hidden Linux flag that tags calls with the phone media role.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('stays off without the flag and exports nothing', () {
    final calls = <String>[];
    final applied = applyCallMediaRole(
      environment: {'PULSE_PROP': 'x=y'},
      setenv: (n, v) {
        calls.add('$n=$v');
        return true;
      },
    );
    expect(applied, isFalse);
    expect(calls, isEmpty);
  });

  test('0 and false count as off', () {
    expect(callMediaRoleRequested({callMediaRoleFlag: '0'}), isFalse);
    expect(callMediaRoleRequested({callMediaRoleFlag: 'False'}), isFalse);
    expect(callMediaRoleRequested({callMediaRoleFlag: ''}), isFalse);
  });

  test('exports media.role=phone as PULSE_PROP when the flag is on', () {
    final calls = <String>[];
    final applied = applyCallMediaRole(
      environment: {callMediaRoleFlag: '1'},
      setenv: (n, v) {
        calls.add('$n=$v');
        return true;
      },
    );
    expect(applied, isTrue);
    expect(calls, ['PULSE_PROP=media.role=phone']);
  });

  test('keeps what the user already exported and replaces an old role', () {
    expect(pulsePropWithCallRole('a=b media.role=music c=d'),
        'a=b c=d media.role=phone');
    expect(pulsePropWithCallRole(null), 'media.role=phone');
  });
}
