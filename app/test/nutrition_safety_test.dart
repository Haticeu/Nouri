import 'package:flutter_test/flutter_test.dart';
import 'package:nouri/core/nutrition_safety.dart';

void main() {
  test('no warnings for a normal target', () {
    expect(targetWarnings(calories: 1800, proteinG: 110, carbsG: 200, fatG: 62), isEmpty);
  });

  test('caution below 1200 kcal, requires confirmation', () {
    final w = targetWarnings(calories: 1100);
    expect(w.single.level, SafetyLevel.caution);
    expect(needsConfirmation(w), isTrue);
  });

  test('danger below 800 kcal', () {
    expect(targetWarnings(calories: 750).single.level, SafetyLevel.danger);
  });

  test('boundaries are inclusive of the safe side', () {
    expect(targetWarnings(calories: 1200), isEmpty);
    expect(targetWarnings(calories: 800).single.level, SafetyLevel.caution);
  });

  test('macro mismatch is info only and does not need confirmation', () {
    final w = targetWarnings(calories: 2000, proteinG: 100, carbsG: 100, fatG: 30);
    expect(w.single.level, SafetyLevel.info);
    expect(needsConfirmation(w), isFalse);
  });
}
