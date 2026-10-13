// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-person playback volume, kept on this device between launches.
///
/// One JSON object of user id to multiplier; a person at the default is
/// absent so the entry does not outlive the choice.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'providers.dart';

const _volumesKey = 'slimm.voice.participant_volumes';

/// Every saved volume, empty when none were saved or the value is unreadable.
Future<Map<String, double>> loadParticipantVolumes(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  final raw = prefs.getString(_volumesKey);
  if (raw == null) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is num)
          entry.key as String: clampParticipantVolume(
            (entry.value as num).toDouble(),
          ),
    };
  } on FormatException {
    return {};
  }
}

/// Saves [volume] for [identity], dropping the entry at the default.
Future<void> saveParticipantVolume(
  Ref ref,
  String identity,
  double volume,
) async {
  final saved = await loadParticipantVolumes(ref);
  if (volume == kDefaultParticipantVolume) {
    saved.remove(identity);
  } else {
    saved[identity] = volume;
  }
  final prefs = await ref.read(preferencesProvider.future);
  await prefs.setString(_volumesKey, jsonEncode(saved));
}
