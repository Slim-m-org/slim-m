// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bare `dart:io` `Platform` member (`isX`, `operatingSystem`, `environment`,
/// ...) throws on the web build, so client code asks `slimm_platform` instead;
/// only the native-only files below use it, in any package.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slimm_test_support/source_gates.dart';

/// Shrink-only: a file leaves this list once it goes through `slimm_platform`.
const _nativeOnly = {
  'app/lib/src/desktop/display_server.dart',
  'app/lib/src/desktop/self_update/update_download.dart',
  'app/lib/src/desktop/startup_updates.dart',
  'app/lib/src/downloads/download_target_io.dart',
  // Added when the gate began to cover every package and every Platform member.
  'api/lib/src/windows_roots_io.dart',
  'app/lib/src/desktop/relaunch.dart',
  'app/lib/src/desktop/self_update/self_update_controller.dart',
  'app/lib/src/desktop/self_update/self_update_target.dart',
  'app/lib/src/desktop/self_update/update_manifest.dart',
  'app/lib/src/desktop/self_update/windows_adopt.dart',
  'app/lib/src/desktop/update_check.dart',
  'app/lib/src/providers/windows_adopt.dart',
  'data/lib/src/connection/encrypted_database.dart',
  'platform/lib/src/autostart_io.dart',
  'platform/lib/src/clipboard_file_writer_io.dart',
  'platform/lib/src/global_hotkeys_io.dart',
  'platform/lib/src/host_platform.dart',
  'platform/lib/src/install_format.dart',
  'platform/lib/src/kwin_window_rule.dart',
  'platform/lib/src/now_playing_io.dart',
  'platform/lib/src/persistent_key_store.dart',
  'platform/lib/src/system_idle_io.dart',
  'rtc/lib/src/call_media_role_host_io.dart',
  'rtc/lib/src/endpoint_effects_io.dart',
  'rtc/lib/src/os_mic_block_io.dart',
  'rtc/lib/src/pulse_audio_io.dart',
  'rtc/lib/src/share_audio_graph_io.dart',
};

final _platformProbe = RegExp(
  r'\bPlatform\s*\.\s*(?:is[A-Z]\w*|operatingSystem|operatingSystemVersion|'
  r'environment|resolvedExecutable|executable|executableArguments|version|'
  r'localHostname|numberOfProcessors|localeName|pathSeparator|script)\b',
);

Iterable<File> _clientSources() sync* {
  for (final pkg in Directory('..').listSync().whereType<Directory>()) {
    final lib = Directory('${pkg.path}/lib');
    if (!lib.existsSync()) continue;
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart')) yield file;
    }
  }
}

String _relative(File file) => file.path.replaceFirst('../', '');

void main() {
  final readers = {
    for (final file in _clientSources())
      if (_platformProbe.hasMatch(codeOnly(file.readAsStringSync())))
        _relative(file),
  };

  test('only native-only files probe dart:io Platform directly', () {
    expect(readers.difference(_nativeOnly), isEmpty);
  });

  test('the native-only list holds no file that stopped probing Platform', () {
    expect(_nativeOnly.difference(readers), isEmpty);
  });

  test('the probe sees every member and ignores comments and strings', () {
    bool probes(String source) => _platformProbe.hasMatch(codeOnly(source));

    expect(probes('final o = Platform.operatingSystem;'), isTrue);
    expect(probes('final e = Platform.environment["HOME"];'), isTrue);
    expect(probes('if (Platform . isLinux) {}'), isTrue);
    expect(probes('// Platform.environment'), isFalse);
    expect(probes("final s = 'Platform.version';"), isFalse);
    expect(probes('final p = TargetPlatform.android;'), isFalse);
  });
}
