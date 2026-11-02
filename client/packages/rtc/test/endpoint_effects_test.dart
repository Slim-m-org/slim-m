// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart' hide windowsMicEffectsLine;
import 'package:slimm_rtc/src/endpoint_effects_io.dart';

const _guid = '{aaaaaaaa-1111-2222-3333-444444444444}';
const _apo = '{bbbbbbbb-1111-2222-3333-444444444444}';

ProcessResult _ok(String out) => ProcessResult(0, 0, out, '');

Future<ProcessResult> _registry(List<String> args, {required int enh}) async {
  final key = args[1];
  if (key.endsWith('Capture')) {
    return _ok('HKEY_LOCAL_MACHINE\\x\\Capture\\$_guid\r\n');
  }
  if (args.contains('DeviceState')) {
    return _ok('    DeviceState    REG_DWORD    0x1\r\n');
  }
  if (key.endsWith('FxProperties')) {
    return _ok(
      '    {d04e05a6-594b-4fb6-a80d-01af5eed7d1d},5    REG_SZ    $_apo\r\n'
      '    {1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5    REG_DWORD    0x$enh\r\n',
    );
  }
  return ProcessResult(0, 1, '', '');
}

void main() {
  test('reads nothing off Windows', () async {
    expect(await windowsMicEffectsLine(windows: false, query: (_) => throw 1),
        isNull);
  });

  test('names the APOs and enhancements state of the default endpoint',
      () async {
    final line = await windowsMicEffectsLine(
      windows: true,
      query: (List<String> a) => _registry(a, enh: 0),
    );
    expect(line, contains('enhancements=on'));
    expect(line, contains('apos=1 [$_apo]'));
    expect(line, startsWith('Windows mic effects: $_guid'));
  });

  test('reports enhancements off when system effects are disabled', () async {
    final line = await windowsMicEffectsLine(
      windows: true,
      inputId: '{0.0.1.00000000}.$_guid',
      query: (List<String> a) => _registry(a, enh: 1),
    );
    expect(line, contains('enhancements=off'));
  });

  test('an inactive endpoint is skipped', () async {
    final line = await windowsMicEffectsLine(
      windows: true,
      query: (List<String> a) async => a.contains('DeviceState')
          ? _ok('    DeviceState    REG_DWORD    0x4\r\n')
          : _registry(a, enh: 0),
    );
    expect(line, contains('no active capture endpoint'));
  });

  test('the call report carries the line under Audio', () {
    final d = CallDiagnostics()..begin();
    d.noteEffectsLine('Windows mic effects: x');
    expect(
        d.report(facts: const {}), contains('Audio\nWindows mic effects: x'));
    d.end();
    d.begin();
    expect(d.report(facts: const {}), isNot(contains('Windows mic effects')));
  });
}
