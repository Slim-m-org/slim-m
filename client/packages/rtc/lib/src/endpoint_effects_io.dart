// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Windows can run its own effects on the microphone on top of ours, so the
/// answer comes from the endpoint keys the Sound settings page writes.
library;

import 'dart:io';

import 'endpoint_effects_parse.dart';

typedef EffectsRegQuery = Future<ProcessResult> Function(List<String> args);

Future<ProcessResult> _reg(List<String> args) => Process.run('reg', args);

Future<String> _out(EffectsRegQuery run, List<String> args) async {
  final result = await run(args);
  return result.exitCode == 0 ? result.stdout as String : '';
}

/// One log line about the effects on [inputId]'s endpoint, or on every active
/// capture endpoint when it is the system default; null off Windows.
Future<String?> windowsMicEffectsLine({
  String? inputId,
  EffectsRegQuery? query,
  bool? windows,
}) async {
  if (!(windows ?? Platform.isWindows)) return null;
  final run = query ?? _reg;
  final chosen = endpointGuidOf(inputId);
  final guids = chosen != null
      ? [chosen]
      : endpointGuidsIn(await _out(run, ['query', windowsCaptureEndpointsKey]));
  final found = <EndpointEffects>[];
  for (final guid in guids) {
    final key = '$windowsCaptureEndpointsKey\\$guid';
    if (!endpointIsActive(
        await _out(run, ['query', key, '/v', 'DeviceState']))) {
      continue;
    }
    final fx = await _out(run, ['query', '$key\\FxProperties']);
    final props = await _out(run, ['query', '$key\\Properties']);
    found.add(EndpointEffects.parse(guid, '$fx\n$props'));
  }
  return endpointEffectsLine(found);
}
