// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Voice pane's half of the settings search index; see `settings_index.dart`.
library;

import 'package:slimm_platform/platform.dart';

import 'settings_index.dart';

const voiceSettingsIndex = <SettingsEntry>[
  SettingsEntry(
    'voice',
    'Hold a key to talk',
    description: 'Hold the key to talk; your mic indicator stays on in calls.',
    keywords: ['push to talk', 'ptt', 'keybind', 'hotkey'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Shortcuts',
    keywords: ['keybind', 'hotkey', 'keyboard'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Mute shortcut',
    keywords: ['mute', 'hotkey', 'keybind', 'global', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Deafen shortcut',
    keywords: ['deafen', 'hotkey', 'keybind', 'global', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Reset shortcuts',
    keywords: ['default', 'keybind', 'hotkey'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Join with camera on',
    description: 'Calls still connect without a camera.',
    keywords: ['video', 'webcam'],
  ),
  SettingsEntry(
    'voice',
    'Mirror my view',
    description: 'Others always see you unmirrored.',
    keywords: ['video', 'webcam', 'flip', 'camera', 'selfie'],
  ),
  SettingsEntry(
    'voice',
    'Share device audio',
    keywords: ['screen share audio', 'system audio'],
  ),
  SettingsEntry(
    'voice',
    'Pause video when minimised',
    description: 'Stops receiving video while the window is minimised.',
  ),
  SettingsEntry(
    'voice',
    'Join and leave sounds',
    description: 'Off automatically in busy calls.',
    keywords: ['sound', 'chime'],
  ),
  SettingsEntry('voice', 'Incoming call sound', keywords: ['ring', 'ringtone']),
  SettingsEntry('voice', 'Music while alone', keywords: ['hold music']),
  SettingsEntry(
    'voice',
    'Microphone',
    description: 'Your input level while you are in a call.',
    keywords: ['mic', 'input', 'level', 'gate', 'sensitivity', 'threshold'],
  ),
  SettingsEntry(
    'voice',
    'Switch if mic stops working',
    description: 'Use another microphone when yours goes silent.',
    keywords: ['mic', 'fallback', 'silent', 'input', 'device'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Speaker',
    keywords: ['output', 'headphones', 'headset', 'audio device'],
  ),
  SettingsEntry(
    'voice',
    'Watching',
    description: 'Video and screens from others.',
    keywords: ['video quality'],
  ),
  SettingsEntry('voice', 'Your camera', keywords: ['webcam', 'video']),
  SettingsEntry(
    'voice',
    'Screen share resolution',
    keywords: ['stream', 'quality', '1080p', '720p'],
  ),
  SettingsEntry(
    'voice',
    'Screen share frame rate',
    keywords: ['stream', 'fps', '60fps'],
  ),
  SettingsEntry(
    'voice',
    'Devices',
    description: 'What a call uses to hear, speak and show you.',
    keywords: ['mic', 'microphone', 'speaker', 'camera', 'input', 'output'],
  ),
  SettingsEntry(
    'voice',
    'Video quality',
    description: 'Lower it to save data, raise it to see more.',
  ),
  SettingsEntry('voice', 'Sharing and preview', keywords: ['screen share']),
  SettingsEntry('voice', 'Sounds', keywords: ['audio', 'chime']),
  SettingsEntry(
    'voice',
    'Noise suppression',
    description: 'Strong also removes keyboards, fans and room noise.',
    keywords: ['noise', 'background noise', 'keyboard', 'rnnoise', 'strong'],
    conditional: true,
    available: _inputGate,
  ),
];

bool _desktop() => isDesktopHost;

bool _inputGate() => isLinuxHost || isWindowsHost;
