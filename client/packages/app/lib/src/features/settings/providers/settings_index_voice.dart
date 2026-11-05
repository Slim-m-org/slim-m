// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Voice pane's half of the settings search index; see `settings_index.dart`.
library;

import 'package:slimm_platform/platform.dart';

import '../../../routing/routes.dart' show desktopPane;

import 'settings_index.dart';

const voiceSettingsIndex = <SettingsEntry>[
  SettingsEntry(
    desktopPane,
    'Hold a key to talk',
    description: 'Your mic indicator stays on in calls.',
    keywords: ['push to talk', 'ptt', 'keybind', 'hotkey'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
    'Shortcuts',
    keywords: ['keybind', 'hotkey', 'keyboard'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
    'Mute shortcut',
    keywords: ['mute', 'hotkey', 'keybind', 'global', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
    'Deafen shortcut',
    keywords: ['deafen', 'hotkey', 'keybind', 'global', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
    'Camera shortcut',
    keywords: ['camera', 'video', 'hotkey', 'keybind', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
    'Share shortcut',
    keywords: ['screen share', 'hotkey', 'keybind', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
    'Leave shortcut',
    keywords: ['hang up', 'call', 'hotkey', 'keybind', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
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
    description: 'Includes sound playing on this device.',
    keywords: ['screen share audio', 'system audio'],
  ),
  SettingsEntry(
    'voice',
    'Viewers draw on my screen',
    description: 'Their marks show on the screen you share for a few seconds.',
    keywords: ['annotate', 'draw', 'marks', 'screen share'],
  ),
  SettingsEntry(
    'voice',
    'Call overlay',
    description: 'Lists who is in the call over your other windows.',
    keywords: ['overlay', 'who is talking', 'speaking', 'corner', 'position'],
    conditional: true,
  ),
  SettingsEntry(
    'voice',
    'Pause video when minimised',
    description: 'Stops receiving video while the window is minimised.',
  ),
  SettingsEntry(
    'notifications',
    'Join and leave sounds',
    description: 'Off automatically in busy calls.',
    keywords: ['sound', 'chime', 'voice', 'call'],
  ),
  SettingsEntry(
    'notifications',
    'Incoming call sound',
    keywords: ['ring', 'ringtone', 'voice'],
  ),
  SettingsEntry(
    'notifications',
    'Music while alone',
    keywords: ['hold music', 'voice'],
  ),
  SettingsEntry('notifications', 'Call sounds', keywords: ['voice', 'audio']),
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
    description: 'How sharp the video you watch is.',
    keywords: ['video quality'],
  ),
  SettingsEntry(
    'voice',
    'Your camera',
    description: 'Sharpness of the camera video you send.',
    keywords: ['webcam', 'video'],
  ),
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
