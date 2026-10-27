// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The font steps of a text box, by the key the wire carries as `props.size`.
library;

/// World-unit font size per step; the app holds these equal to its type scale (`AppText.ui`, `heading`, `title`), which this package cannot import.
const Map<String, double> canvasTextFontSizes = {
  'small': 14,
  'medium': 20,
  'large': 24,
};

const String canvasDefaultTextSize = 'medium';

/// Line height shared by the painter and the app's sizing of a new box.
const double canvasTextLineHeight = 1.3;

/// Inset between a text box's edge and its glyphs, in world units.
const double canvasTextPad = 4;

/// The wire colour key for text that follows the theme's ink.
const String canvasDefaultTextColor = 'ink';
