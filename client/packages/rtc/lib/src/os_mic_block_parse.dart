// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading `reg query` output for the microphone consent store.
library;

/// The consent keys Windows consults, the global one first and then the one
/// for desktop apps, which is the switch this app falls under.
const List<String> windowsMicConsentKeys = [
  r'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
  r'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged',
];

/// True when a `reg query <key> /v Value` output says `Deny`.
bool consentIsDeny(String output) => RegExp(
      r'^\s*Value\s+REG_SZ\s+Deny\s*$',
      multiLine: true,
      caseSensitive: false,
    ).hasMatch(output);
