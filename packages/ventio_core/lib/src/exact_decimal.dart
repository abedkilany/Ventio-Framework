/// Fixed scale decimal helpers used by declarative calculations and Host
/// effects. Arithmetic stays in [BigInt] until a JSON number is required.
class ExactDecimal {
  ExactDecimal._();

  static final BigInt _maxSafeInteger = BigInt.from(9007199254740991);
  static final RegExp _decimalPattern = RegExp(
      r'^([+-]?)(\d+)(?:\.(\d*))?(?:e([+-]?\d+))?$',
      caseSensitive: false);

  /// Converts a finite JSON number to an integer at [scale] decimal places.
  /// Excess fractional digits are accepted only when they are trailing zeros.
  static BigInt toScaledInteger(num value, int scale) {
    if (!value.isFinite || scale < 0 || scale > 9) {
      throw const FormatException('Decimal is outside the supported bounds.');
    }
    final match = _decimalPattern.firstMatch(value.toString().toLowerCase());
    if (match == null) {
      throw const FormatException('Invalid decimal value.');
    }
    final fraction = match.group(3) ?? '';
    final exponent = int.parse(match.group(4) ?? '0');
    final digits = '${match.group(2)}$fraction';
    var scaled = BigInt.parse(digits);
    if (match.group(1) == '-') scaled = -scaled;
    final sourceScale = fraction.length - exponent;
    if (sourceScale < scale) {
      scaled *= BigInt.from(10).pow(scale - sourceScale);
    } else if (sourceScale > scale) {
      final divisor = BigInt.from(10).pow(sourceScale - scale);
      if (scaled.remainder(divisor) != BigInt.zero) {
        throw const FormatException('Decimal exceeds the declared precision.');
      }
      scaled ~/= divisor;
    }
    return scaled;
  }

  /// Converts scaled integer arithmetic back to a JSON-compatible number and
  /// verifies the shortest decimal representation preserves the exact value.
  static num fromScaledInteger(BigInt value, int scale) {
    if (scale < 0 || scale > 9 || value.abs() > _maxSafeInteger) {
      throw const FormatException('Calculated decimal exceeds the safe bound.');
    }
    if (scale == 0) return value.toInt();
    final factor = BigInt.from(10).pow(scale);
    final negative = value.isNegative;
    final absolute = value.abs();
    final whole = absolute ~/ factor;
    final fraction = (absolute % factor).toString().padLeft(scale, '0');
    final text = '${negative ? '-' : ''}$whole.$fraction';
    final number = double.parse(text);
    if (toScaledInteger(number, scale) != value) {
      throw const FormatException(
        'Calculated decimal cannot be represented exactly as a JSON number.',
      );
    }
    return number;
  }

  /// Adds two numbers at a shared scale without binary floating-point math.
  static BigInt add(num left, num right, int scale) =>
      toScaledInteger(left, scale) + toScaledInteger(right, scale);

  /// Multiplies values at their declared scales and converts exactly to the
  /// requested output scale. No implicit rounding is performed.
  static BigInt multiply(
    num left,
    int leftScale,
    num right,
    int rightScale,
    int outputScale,
  ) {
    final product =
        toScaledInteger(left, leftScale) * toScaledInteger(right, rightScale);
    final productScale = leftScale + rightScale;
    if (productScale <= outputScale) {
      return product * BigInt.from(10).pow(outputScale - productScale);
    }
    final divisor = BigInt.from(10).pow(productScale - outputScale);
    if (product.remainder(divisor) != BigInt.zero) {
      throw const FormatException(
        'Calculated product requires rounding beyond the declared precision.',
      );
    }
    return product ~/ divisor;
  }
}
