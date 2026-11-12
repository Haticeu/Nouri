import 'package:flutter_test/flutter_test.dart';
import 'package:nouri/core/goal_calculator.dart';

void main() {
  test('Mifflin-St Jeor for a moderately active woman maintaining', () {
    // 10*65 + 6.25*165 - 5*30 - 161 = 1370.25; x1.55 = 2123.9
    final p = calculateTargets(sex: Sex.female, age: 30, heightCm: 165, weightKg: 65, activity: Activity.moderate, goal: Goal.maintain);
    expect(p.bmr, 1370);
    expect(p.maintenance, 2125);
    expect(p.calories, 2125);
    expect(p.proteinG, 78); // 1.2 g/kg
    expect(p.fatG, 71); // 30% of energy
    expect(p.waterMl, 2250); // ~33 ml/kg, rounded to a glass
  });

  test('macros add up to the calorie target', () {
    final p = calculateTargets(sex: Sex.male, age: 40, heightCm: 180, weightKg: 90, activity: Activity.light, goal: Goal.lose);
    final fromMacros = p.proteinG * 4 + p.carbsG * 4 + p.fatG * 9;
    expect((fromMacros - p.calories).abs(), lessThan(15));
    expect(p.calories, p.maintenance - 500);
  });

  test('never goes below the 1200 kcal unsupervised minimum', () {
    final p = calculateTargets(sex: Sex.female, age: 70, heightCm: 150, weightKg: 45, activity: Activity.sedentary, goal: Goal.lose);
    expect(p.calories, 1200);
    expect(p.raisedToMinimum, isTrue);
  });
}
