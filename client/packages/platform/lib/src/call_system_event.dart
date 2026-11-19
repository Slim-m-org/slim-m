// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What iOS reports around a call - each CallKit step and its result, CallKit
/// activating and deactivating the audio session, the shared
/// `AVAudioSession`'s interruptions and route changes - as plain lines for
/// the call's diagnostics.
///
/// The native side sends raw values (`VoiceCallReporter.swift`) and the words
/// live here, where a test can pin them. Ports are named by type only
/// ("BluetoothHFP"), never by the device's own name, which can carry a
/// person's name.
library;

/// One event as a timeline line, or null for a shape this does not know.
String? describeCallSystemEvent(Map<Object?, Object?> event) =>
    switch (event['kind']) {
      'callKit' => _callKit(event),
      'callKitAudio' => 'CallKit '
          '${event['active'] == true ? 'activated' : 'deactivated'} '
          'the audio session: ${describeAudioSession(event)}',
      'interruption' => _interruption(event),
      'routeChange' =>
        'Audio route changed (${_routeReason(event['reason'])}): '
            '${describeAudioSession(event)}',
      'mediaServicesLost' => 'Audio media services were lost',
      'mediaServicesReset' => 'Audio media services were reset',
      _ => null,
    };

/// The audio session as one phrase: category/mode, the route, and whether
/// another app holds audio.
String describeAudioSession(Map<Object?, Object?> session) {
  final category = _strip(session['category'], 'AVAudioSessionCategory');
  final mode = _strip(session['mode'], 'AVAudioSessionMode');
  final parts = [
    'session $category/$mode',
    'in ${_ports(session['inputs'])}',
    'out ${_ports(session['outputs'])}',
    if (session['otherAudioPlaying'] == true) 'other audio playing',
    if (session['inputAvailable'] == false) 'no input available',
  ];
  return parts.join(', ');
}

String _callKit(Map<Object?, Object?> event) {
  final step = switch (event['step']) {
    'start' => 'start request',
    'startAction' => 'start action',
    'connected' => 'connected report',
    'end' => 'end request',
    'endAction' => 'end action',
    final other => '$other',
  };
  final result = switch (event['result']) {
    'failed' => 'failed (${_error(event)})',
    'skipped' => 'skipped, a call is already reported',
    'noCall' => 'skipped, no call is reported',
    'system' => 'from the system call screen',
    final other => '$other',
  };
  return 'CallKit $step: $result';
}

String _error(Map<Object?, Object?> event) {
  final domain = event['domain'];
  final code = event['code'];
  final name =
      domain == 'com.apple.CallKit.error.requesttransaction' && code is int
          ? _transactionErrors[code]
          : null;
  return [
    domain ?? 'unknown error',
    if (code != null) code,
    if (name != null) name
  ].join(' ');
}

const _transactionErrors = {
  1: 'unknown',
  2: 'unentitled',
  3: 'unknownCallProvider',
  4: 'emptyTransaction',
  5: 'unknownCallUUID',
  6: 'callUUIDAlreadyExists',
  7: 'invalidAction',
  8: 'maximumCallGroupsReached',
  9: 'callIsProtected',
};

String _interruption(Map<Object?, Object?> event) {
  final began = event['type'] == 1;
  final reason = switch (event['reason']) {
    1 => ' (app was suspended)',
    2 => ' (built-in mic muted)',
    4 => ' (route disconnected)',
    null || 0 => '',
    final other => ' (reason $other)',
  };
  final resume = event['options'] == 1 ? ', may resume' : '';
  return 'Audio interruption ${began ? 'began' : 'ended'}$reason$resume';
}

String _routeReason(Object? reason) => switch (reason) {
      1 => 'new device',
      2 => 'device gone',
      3 => 'category change',
      4 => 'override',
      6 => 'wake from sleep',
      7 => 'no route for category',
      8 => 'route configuration',
      0 || null => 'unknown',
      final other => 'reason $other',
    };

String _ports(Object? ports) =>
    ports is List && ports.isNotEmpty ? ports.join('+') : 'none';

String _strip(Object? raw, String prefix) {
  if (raw is! String || raw.isEmpty) return '?';
  final short = raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
  if (short.isEmpty) return raw;
  return short[0].toLowerCase() + short.substring(1);
}
