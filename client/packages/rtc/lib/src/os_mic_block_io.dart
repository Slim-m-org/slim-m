// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Windows hides a denied microphone as digital silence, so the answer comes
/// from the consent store the Privacy settings page writes.
library;

import 'dart:io';

import 'os_mic_block_parse.dart';

typedef RegQuery = Future<ProcessResult> Function(List<String> args);

Future<ProcessResult> _reg(List<String> args) => Process.run('reg', args);

Future<bool> osBlocksMicrophone({RegQuery? query, bool? windows}) async {
  if (!(windows ?? Platform.isWindows)) return false;
  final run = query ?? _reg;
  for (final key in windowsMicConsentKeys) {
    final result = await run(['query', key, '/v', 'Value']);
    if (result.exitCode == 0 && consentIsDeny(result.stdout as String)) {
      return true;
    }
  }
  return false;
}
