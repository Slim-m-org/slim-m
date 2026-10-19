// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Telling a blocked, busy, missing and silent microphone apart.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart' hide osBlocksMicrophone;
import 'package:slimm_rtc/src/os_mic_block_io.dart';
import 'package:slimm_rtc/src/os_mic_block_parse.dart';

ProcessResult _reg(String value, {int code = 0}) => ProcessResult(
      0,
      code,
      '\r\nHKEY_CURRENT_USER\\...\\microphone\r\n    Value    REG_SZ    $value\r\n',
      '',
    );

void main() {
  group('classifyMicFailure', () {
    test('reads the DOMException names every browser and Apple platform use',
        () {
      expect(classifyMicFailure('DOMException, NotAllowedError'),
          MicFailureReason.permissionDenied);
      expect(classifyMicFailure(Exception('NotReadableError: busy')),
          MicFailureReason.busy);
      expect(classifyMicFailure('NotFoundError'), MicFailureReason.notFound);
      expect(classifyMicFailure('boom'), MicFailureReason.unknown);
    });
  });

  group('refineMicFailure', () {
    test('silence or an unknown cause becomes a block when the OS says so',
        () async {
      for (final reason in [
        MicFailureReason.silent,
        MicFailureReason.unknown
      ]) {
        expect(await refineMicFailure(reason, () async => true),
            MicFailureReason.permissionDenied);
        expect(await refineMicFailure(reason, () async => false), reason);
      }
    });

    test('a cause the platform named is never overridden', () async {
      expect(await refineMicFailure(MicFailureReason.busy, () async => true),
          MicFailureReason.busy);
    });

    test('a probe that throws leaves the reason alone', () async {
      expect(
        await refineMicFailure(
            MicFailureReason.silent, () async => throw StateError('no reg')),
        MicFailureReason.silent,
      );
    });
  });

  group('osBlocksMicrophone', () {
    test('is false off Windows without asking', () async {
      var asked = false;
      final blocked = await osBlocksMicrophone(
        windows: false,
        query: (_) async {
          asked = true;
          return _reg('Deny');
        },
      );
      expect(blocked, isFalse);
      expect(asked, isFalse);
    });

    test('is true when either consent key says Deny', () async {
      final keys = <String>[];
      final blocked = await osBlocksMicrophone(
        windows: true,
        query: (args) async {
          keys.add(args[1]);
          return _reg(keys.length == 2 ? 'Deny' : 'Allow');
        },
      );
      expect(blocked, isTrue);
      expect(keys, windowsMicConsentKeys);
    });

    test('is false when both allow or a key is missing', () async {
      expect(
        await osBlocksMicrophone(
            windows: true, query: (_) async => _reg('Allow')),
        isFalse,
      );
      expect(
        await osBlocksMicrophone(
            windows: true, query: (_) async => _reg('Deny', code: 1)),
        isFalse,
      );
    });
  });

  test('consentIsDeny reads output captured from a real Windows 11 machine',
      () {
    const real =
        '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\'
        'CapabilityAccessManager\\ConsentStore\\microphone\\NonPackaged\r\n'
        '    Value    REG_SZ    Deny\r\n\r\n';
    expect(consentIsDeny(real), isTrue);
    expect(consentIsDeny(real.replaceAll('Deny', 'Allow')), isFalse);
  });

  test('consentIsDeny ignores other values', () {
    expect(consentIsDeny('    Value    REG_SZ    Allow'), isFalse);
    expect(consentIsDeny('    Value    REG_SZ    Deny'), isTrue);
  });
}
