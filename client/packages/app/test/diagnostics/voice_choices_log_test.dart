// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show LogLevel, LogRecord, LogSink, AppLog;
import 'package:slimm_app/src/diagnostics/voice_choices_log.dart';

class _Records implements LogSink {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  tearDown(() => AppLog.install(null));

  test('logs the saved choices and never the device id', () async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.noise_suppression': 'strong',
      'slimm.voice.auto_gain': false,
      'slimm.voice.audio_input_device_id': 'secret-device-id',
    });
    final sink = _Records();
    AppLog.install(sink);

    logSavedVoiceChoices(await SharedPreferences.getInstance());

    final record = sink.records.single;
    expect(record.level, LogLevel.info);
    expect(record.context, {
      'noiseSuppression': 'strong',
      'autoGain': 'false',
      'inputDevice': 'set',
    });
  });

  test('says unset for choices never saved', () async {
    SharedPreferences.setMockInitialValues({});
    final sink = _Records();
    AppLog.install(sink);

    logSavedVoiceChoices(await SharedPreferences.getInstance());

    expect(sink.records.single.context, {
      'noiseSuppression': 'unset',
      'autoGain': 'unset',
      'inputDevice': 'unset',
    });
  });
}
