// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a text box is made of: the wire props, the input filter, the font steps and the box a text needs.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_object_inputs.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_text_props.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_text_content.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

api.CanvasObject _object(Map<String, dynamic> props) => api.CanvasObject(
  id: 't',
  kind: 'text',
  zIndex: 1,
  x: 5,
  y: 6,
  w: 100,
  h: 30,
  props: props,
  authorId: 'me',
  seq: 3,
  createdAt: 0,
);

TextEditingValue _typed(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  test(
    'every font step is a step of the design type scale and the canvas mirrors it',
    () {
      expect(canvasTextSizeKeys, canvasTextFontSizes.keys.toList());
      expect(canvasTextScaleSizes, canvasTextFontSizes);
    },
  );

  group('wire props', () {
    test('a text object becomes a text input with its size and colour', () {
      final input = canvasStrokeInputFrom(
        _object({'text': 'hi', 'size': 'large', 'color': 'blue'}),
      )!;
      expect(input.kind, CanvasObjectKind.text);
      expect(input.text, 'hi');
      expect(input.textSize, 'large');
      expect(input.colorKey, 'blue');
    });

    test('a missing or unknown size and colour fall back to the defaults', () {
      final input = canvasStrokeInputFrom(
        _object({'text': 'hi', 'size': 'huge'}),
      )!;
      expect(input.textSize, canvasDefaultTextSize);
      expect(input.colorKey, canvasDefaultTextColor);
    });

    test('a row with no text paints nothing instead of throwing', () {
      expect(canvasStrokeInputFrom(_object({'size': 'small'})), isNull);
      expect(canvasStrokeInputFrom(_object({'text': 4})), isNull);
    });

    test('the props go back out as the same three fields', () {
      const props = CanvasTextProps(text: 'a', size: 'small', colorKey: 'pink');
      expect(CanvasTextProps.fromWire(props.toWire()), props);
      expect(props.toWire(), {'text': 'a', 'size': 'small', 'color': 'pink'});
    });
  });

  group('input filter', () {
    test(
      'hidden and direction characters are stripped, tabs become spaces, line breaks stay',
      () {
        expect(cleanTextBoxInput('a‮b​c\u0007d'), 'abcd');
        expect(cleanTextBoxInput('a\tb'), 'a b');
        expect(cleanTextBoxInput('a\r\nb\rc'), 'a\nb\nc');
        expect(cleanTextBoxInput('café \u{1F600}'), 'café \u{1F600}');
      },
    );

    test('a paste is cleaned and cut at the limit, and says it was cut', () {
      var cut = 0;
      final formatter = TextBoxInputFormatter(onRefused: () => cut++);
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        _typed('‮${'x' * (maxTextBoxChars + 50)}'),
      );
      expect(result.text, 'x' * maxTextBoxChars);
      expect(cut, 1);
    });

    test('an ordinary edit passes through untouched', () {
      final value = _typed('plain');
      expect(
        const TextBoxInputFormatter().formatEditUpdate(
          TextEditingValue.empty,
          value,
        ),
        value,
      );
    });
  });

  group('box fit', () {
    const small = CanvasTextProps(text: 'hello', size: 'small');

    test('a longer text or a larger step needs a taller box', () {
      final one = textBoxFor(small);
      final many = textBoxFor(
        small.copyWith(text: List.filled(40, 'word').join(' ')),
      );
      final large = textBoxFor(small.copyWith(size: 'large'));
      expect(many.height, greaterThan(one.height));
      expect(large.height, greaterThan(one.height));
    });

    test('a line break adds a line and the width is the one asked for', () {
      final box = textBoxFor(small.copyWith(text: 'a\nb\nc'), width: 120);
      expect(box.width, 120);
      expect(box.height, greaterThan(textBoxFor(small, width: 120).height * 2));
    });
  });
}
