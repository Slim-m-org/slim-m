// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text box's input filter, its size samples, and the box a given text needs.
library;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../providers/canvas_text_props.dart';

/// A text box's world width when it is first placed.
const double defaultTextBoxWidth = 240;

/// The design style each font step is drawn with, for the sample letters in the editor.
TextStyle canvasTextSizeSample(String key) => switch (key) {
  'small' => AppText.ui,
  'large' => AppText.title,
  _ => AppText.heading,
};

/// Cleans every edit and cuts it to [maxTextBoxChars] code points, so a paste of hidden characters can never reach the wire.
class TextBoxInputFormatter extends TextInputFormatter {
  const TextBoxInputFormatter({this.onRefused});

  final VoidCallback? onRefused;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = cleanTextBoxInput(newValue.text);
    if (text.runes.length > maxTextBoxChars) {
      text = String.fromCharCodes(text.runes.take(maxTextBoxChars));
      onRefused?.call();
    }
    if (text == newValue.text) return newValue;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: newValue.selection.baseOffset.clamp(0, text.length),
      ),
    );
  }
}

/// The box [props] needs when wrapped at [width]: tall enough for every line, never below one line.
({double width, double height}) textBoxFor(
  CanvasTextProps props, {
  double width = defaultTextBoxWidth,
}) {
  final fontSize = canvasTextFontSizes[props.size]!;
  final painter = TextPainter(
    text: TextSpan(
      text: props.text,
      style: TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: fontSize,
        height: canvasTextLineHeight,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width - canvasTextPad * 2);
  final height = (painter.height + canvasTextPad * 2).ceilToDouble();
  painter.dispose();
  return (width: width, height: height.clamp(minObjectSize, maxObjectExtent));
}
