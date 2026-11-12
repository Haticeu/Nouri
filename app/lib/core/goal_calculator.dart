/// Personal targets for people using Nouri on their own (no dietitian).
///
/// Energy: Mifflin-St Jeor resting energy x activity factor, then a deficit or
/// surplus for the goal. Never below 1200 kcal (the unsupervised minimum used
/// across the app, see nutrition_safety.dart).
/// Protein by body weight, fat 30% of energy, carbohydrate the rest.
library;

import 'dart:math' as math;

import 'nutrition_safety.dart';

enum Sex { female, male, other }

enum Activity {
  sedentary(1.2, 'Mostly sitting', 'Desk job, little exercise'),
  light(1.375, 'Lightly active', 'Walks, exercise 1–3 days a week'),
  moderate(1.55, 'Moderately active', 'Exercise 3–5 days a week'),
  active(1.725, 'Very active', 'Hard exercise 6–7 days a week'),
  athlete(1.9, 'Athlete', 'Physical job or training twice a day');

  const Activity(this.factor, this.label, this.hint);
  final double factor;
  final String label;
  final String hint;
}

enum Goal {
  lose(-500, 'Lose weight', 'About 0.5 kg a week', 1.6),
  loseSlow(-250, 'Lose slowly', 'About 0.25 kg a week', 1.6),
  maintain(0, 'Maintain', 'Keep your current weight', 1.2),
  gain(300, 'Gain weight', 'Lean, gradual gain', 1.6);

  const Goal(this.kcalDelta, this.label, this.hint, this.proteinPerKg);
  final int kcalDelta;
  final String label;
  final String hint;
  final double proteinPerKg;
}

class TargetPlan {
  const TargetPlan({
    required this.bmr,
    required this.maintenance,
    required this.calories,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.waterMl,
    required this.raisedToMinimum,
  });

  final int bmr; // resting energy
  final int maintenance; // to keep current weight
  final int calories;
  final int proteinG;
  final int carbsG;
  final int fatG;
  final int waterMl;
  final bool raisedToMinimum; // the goal would have gone below the safe minimum
}

TargetPlan calculateTargets({
  required Sex sex,
  required int age,
  required double heightCm,
  required double weightKg,
  required Activity activity,
  required Goal goal,
}) {
  final sexTerm = switch (sex) { Sex.male => 5.0, Sex.female => -161.0, Sex.other => -78.0 };
  final bmr = 10 * weightKg + 6.25 * heightCm - 5 * age + sexTerm;
  final maintenance = bmr * activity.factor;
  final wanted = maintenance + goal.kcalDelta;
  final calories = math.max(wanted, kMinCaloriesUnsupervised.toDouble());

  final protein = math.min(weightKg * goal.proteinPerKg, weightKg * 2.2);
  final fat = calories * 0.30 / 9;
  final carbs = math.max(0.0, (calories - protein * 4 - fat * 9) / 4);
  // ~33 ml per kg, rounded to a glass (250 ml), within 1.5–4 L.
  final water = ((weightKg * 33 / 250).round() * 250).clamp(1500, 4000);

  int r5(double v) => (v / 5).round() * 5;
  return TargetPlan(
    bmr: bmr.round(),
    maintenance: r5(maintenance),
    calories: r5(calories),
    proteinG: protein.round(),
    carbsG: carbs.round(),
    fatG: fat.round(),
    waterMl: water,
    raisedToMinimum: wanted < kMinCaloriesUnsupervised,
  );
}
