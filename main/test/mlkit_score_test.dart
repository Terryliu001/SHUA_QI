import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/infra/ocr/mlkit_ink_engine.dart';

void main() {
  test('ML Kit score 越小置信越高，并落在 0..1', () {
    expect(confidenceFromMlKitScore(0), closeTo(0.5, 0.001));
    expect(confidenceFromMlKitScore(-1), greaterThan(0.7));
    expect(confidenceFromMlKitScore(-2), greaterThan(0.85));
    expect(confidenceFromMlKitScore(3), lessThan(0.1));
    expect(confidenceFromMlKitScore(double.nan), 0.5);
    for (final double score in <double>[-10, -1, 0, 1, 10]) {
      final double value = confidenceFromMlKitScore(score);
      expect(value, inInclusiveRange(0.05, 0.99));
    }
  });
}
