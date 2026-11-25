// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading `reg query` output for the microphone consent store.
library;

/// The consent keys Windows consults, the global one first and then the one
/// for desktop apps, which is the switch this app falls under. The machine
/// store counts as well as the user's own.
const List<String> windowsMicConsentKeys = [
  r'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
  r'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged',
  r'HKLM\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
  r'HKLM\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged',
];

/// The group policy "Let Windows apps access the microphone" writes.
const String windowsMicPolicyKey =
    r'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';
const String windowsMicPolicyValue = 'LetAppsAccessMicrophone';

/// True when a `reg query <key> /v Value` output says `Deny`.
bool consentIsDeny(String output) => RegExp(
      r'^\s*Value\s+REG_SZ\s+Deny\s*$',
      multiLine: true,
      caseSensitive: false,
    ).hasMatch(output);

/// True when a `reg query <key> /v LetAppsAccessMicrophone` output is the
/// policy's "force deny" (2).
bool policyForcesMicDeny(String output) => RegExp(
      '^\\s*$windowsMicPolicyValue\\s+REG_DWORD\\s+0x0*2\\s*\$',
      multiLine: true,
      caseSensitive: false,
    ).hasMatch(output);
