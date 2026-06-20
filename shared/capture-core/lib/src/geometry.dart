/// Normalized geometry used throughout the capture reconstruction core.
///
/// COORDINATE CONVENTION (every platform adapter MUST match this):
/// coordinates are normalized to the unit square `[0, 1]`, with the ORIGIN at
/// the BOTTOM-LEFT and the y-axis pointing UP — i.e. Apple Vision's native
/// `boundingBox` convention. The macOS adapter emits Vision boxes directly. A
/// future Windows adapter MUST convert `Windows.Media.Ocr`'s top-left / pixel
/// boxes into this exact space so the shared reconstruction logic below is
/// byte-for-byte identical on every platform.
library;

/// A point in normalized OCR space (bottom-left origin, y up).
class NormPoint {
  final double x;
  final double y;

  const NormPoint(this.x, this.y);

  factory NormPoint.fromMap(Map<dynamic, dynamic> map) => NormPoint(
        (map['x'] as num).toDouble(),
        (map['y'] as num).toDouble(),
      );

  Map<String, double> toMap() => {'x': x, 'y': y};

  @override
  String toString() => 'NormPoint($x, $y)';
}

/// An axis-aligned rectangle in normalized OCR space (bottom-left origin, y up).
///
/// [x]/[y] are the bottom-left corner; [width]/[height] extend right and up.
class NormRect {
  final double x;
  final double y;
  final double width;
  final double height;

  const NormRect(this.x, this.y, this.width, this.height);

  factory NormRect.fromMap(Map<dynamic, dynamic> map) => NormRect(
        (map['x'] as num).toDouble(),
        (map['y'] as num).toDouble(),
        (map['width'] as num).toDouble(),
        (map['height'] as num).toDouble(),
      );

  Map<String, double> toMap() => {'x': x, 'y': y, 'width': width, 'height': height};

  double get minX => x;
  double get maxX => x + width;
  double get minY => y;
  double get maxY => y + height;
  double get midX => x + width / 2;
  double get midY => y + height / 2;

  bool get isEmpty => width <= 0 || height <= 0;

  bool contains(NormPoint p) => p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY;

  /// Horizontal overlap ratio with [other], relative to this rect's width.
  /// 0 when they do not overlap on the x-axis.
  double horizontalOverlapRatio(NormRect other) {
    final lo = minX > other.minX ? minX : other.minX;
    final hi = maxX < other.maxX ? maxX : other.maxX;
    final overlap = hi - lo;
    if (overlap <= 0 || width <= 0) return 0;
    return overlap / width;
  }

  @override
  String toString() => 'NormRect(x: $x, y: $y, w: $width, h: $height)';
}
