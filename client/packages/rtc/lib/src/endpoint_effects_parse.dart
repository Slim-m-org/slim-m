// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading `reg query` output for a capture endpoint's audio effects.
library;

const String windowsCaptureEndpointsKey =
    r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture';

const String _disableSysFxFmtid = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e}';
final RegExp _guid = RegExp(
  r'\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}',
  caseSensitive: false,
);
final RegExp _valueLine = RegExp(
  r'^\s*(\{[^}]+\}),(\d+)\s+(REG_\w+)\s+(.*?)\s*$',
  multiLine: true,
  caseSensitive: false,
);

/// The endpoint GUID inside a device id, or null for the system default.
String? endpointGuidOf(String? deviceId) =>
    deviceId == null ? null : _guid.allMatches(deviceId).lastOrNull?.group(0);

/// The endpoint GUIDs a `reg query` of the capture key lists.
List<String> endpointGuidsIn(String output) => [
      for (final line in output.split(RegExp(r'\r?\n')))
        if (RegExp(r'^HKEY_\w+\\.*\\\{[^}]+\}\s*$', caseSensitive: false)
            .hasMatch(line.trim()))
          _guid.allMatches(line).last.group(0)!,
    ];

/// True when a `reg query <key> /v DeviceState` output says the endpoint is active.
bool endpointIsActive(String output) => RegExp(
      r'^\s*DeviceState\s+REG_DWORD\s+0x1\s*$',
      multiLine: true,
      caseSensitive: false,
    ).hasMatch(output);

/// What one endpoint's keys say about Windows processing its signal.
class EndpointEffects {
  const EndpointEffects({
    required this.guid,
    required this.enhancements,
    required this.apos,
  });

  final String guid;

  /// The "Audio Enhancements" switch: false when the endpoint disables system effects.
  final bool enhancements;

  /// Effect (APO) class ids the endpoint's FxProperties names.
  final List<String> apos;

  /// Reads the output of `reg query` over the endpoint's FxProperties and Properties keys.
  factory EndpointEffects.parse(String guid, String output) {
    var enhancements = true;
    final apos = <String>[];
    for (final m in _valueLine.allMatches(output)) {
      final fmtid = m.group(1)!.toLowerCase();
      final type = m.group(3)!.toUpperCase();
      final data = m.group(4)!;
      if (fmtid == _disableSysFxFmtid && m.group(2) == '5') {
        enhancements =
            !RegExp(r'^0x0*[1-9a-f]', caseSensitive: false).hasMatch(data);
      } else if (type == 'REG_SZ' && _guid.matchAsPrefix(data) != null) {
        if (!apos.contains(data.toLowerCase())) apos.add(data.toLowerCase());
      }
    }
    return EndpointEffects(guid: guid, enhancements: enhancements, apos: apos);
  }

  String get summary => '$guid enhancements=${enhancements ? 'on' : 'off'} '
      'apos=${apos.length}${apos.isEmpty ? '' : ' [${apos.join(',')}]'}';
}

/// The one line a call report and the debug log carry.
String endpointEffectsLine(List<EndpointEffects> found) => found.isEmpty
    ? 'Windows mic effects: no active capture endpoint found'
    : 'Windows mic effects: ${found.map((e) => e.summary).join('; ')}';
