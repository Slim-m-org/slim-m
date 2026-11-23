// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last `setInputGate` settings, kept for a worklet that loads later.
library;

import 'input_gate.dart' show kDefaultInputThresholdDb;

class WebCaptureChainSettings {
  bool _enabled = false;
  double _thresholdDb = kDefaultInputThresholdDb;
  bool _dynamics = false;
  bool _levelAfterSuppression = false;
  bool _strong = false;

  /// Takes the `setInputGate` map; Strongest is desktop only and ignored.
  void update(Object? args) {
    if (args is! Map) return;
    _enabled = args['enabled'] == true;
    _thresholdDb =
        (args['thresholdDb'] as num?)?.toDouble() ?? kDefaultInputThresholdDb;
    _dynamics = args['dynamics'] == true;
    _levelAfterSuppression = args['levelAfterSuppression'] == true;
    _strong = args['strongNoiseSuppression'] == true;
  }

  /// What the worklet's `configure` message carries.
  Map<String, Object> get message => {
        'type': 'configure',
        'enabled': _enabled,
        'thresholdDb': _thresholdDb,
        'dynamics': _dynamics,
        'levelAfterSuppression': _levelAfterSuppression,
        'strongNoiseSuppression': _strong,
      };
}
