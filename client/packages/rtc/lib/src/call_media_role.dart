// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tags this process's sound-server streams as a call on Linux, behind a hidden flag.
///
/// libwebrtc's Pulse backend sets no `media.role`, so WirePlumber never sees a
/// Communication stream and will not switch a Bluetooth headset to its mic
/// profile (docs/research/mic-handling.md, P10). libpulse reads `PULSE_PROP`
/// once, when libwebrtc opens its one context, so this has to run before the
/// first audio call and cannot be scoped to a single call.
library;

import 'call_media_role_host_web.dart'
    if (dart.library.io) 'call_media_role_host_io.dart';

/// The process environment variable that switches this on; never in settings.
const callMediaRoleFlag = 'SLIMM_CALL_MEDIA_ROLE';

const _roleProp = 'media.role=phone';

bool callMediaRoleRequested(Map<String, String> environment) {
  final flag = environment[callMediaRoleFlag];
  return flag != null &&
      flag.isNotEmpty &&
      flag != '0' &&
      flag.toLowerCase() != 'false';
}

/// [existing] with the call role added, keeping whatever else the user exported.
String pulsePropWithCallRole(String? existing) {
  final kept = (existing ?? '')
      .split(' ')
      .where((p) => p.isNotEmpty && !p.startsWith('media.role='));
  return [...kept, _roleProp].join(' ');
}

typedef ProcessSetenv = bool Function(String name, String value);

/// Exports the call role when the hidden flag is on; true when it did.
bool applyCallMediaRole({
  Map<String, String>? environment,
  ProcessSetenv? setenv,
}) {
  final env = environment ?? hostEnvironment();
  if (!callMediaRoleRequested(env)) return false;
  return (setenv ?? hostSetenv)(
      'PULSE_PROP', pulsePropWithCallRole(env['PULSE_PROP']));
}
