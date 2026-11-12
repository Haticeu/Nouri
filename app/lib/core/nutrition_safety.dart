/// Safety checks for calorie/macro targets. Used for BOTH client-set and
/// dietitian-set targets: when editing (with a confirmation step) and when
/// displaying targets to the client.
library;

import 'i18n.dart';

const int kMinCaloriesUnsupervised = 1200;
const int kVeryLowCalories = 800;

enum SafetyLevel { info, caution, danger }

class TargetWarning {
  const TargetWarning(this.level, this.message);
  final SafetyLevel level;
  final String message;
}

List<TargetWarning> targetWarnings({
  int? calories,
  int? proteinG,
  int? carbsG,
  int? fatG,
}) {
  final warnings = <TargetWarning>[];
  if (calories != null) {
    if (calories < kVeryLowCalories) {
      warnings.add(TargetWarning(
        SafetyLevel.danger,
        t('Under {0} kcal/day is a very-low-calorie diet. It is only appropriate under close medical supervision.', [kVeryLowCalories]),
      ));
    } else if (calories < kMinCaloriesUnsupervised) {
      warnings.add(TargetWarning(
        SafetyLevel.caution,
        t('Below {0} kcal/day, the usual minimum for adults without medical supervision.', [kMinCaloriesUnsupervised]),
      ));
    }
  }
  if (calories != null && calories > 0 && proteinG != null && carbsG != null && fatG != null) {
    final fromMacros = proteinG * 4 + carbsG * 4 + fatG * 9;
    if ((fromMacros - calories).abs() / calories > 0.15) {
      warnings.add(TargetWarning(
        SafetyLevel.info,
        t('Macros add up to {0} kcal, which differs from the {1} kcal target by more than 15%.', [fromMacros, calories]),
      ));
    }
  }
  return warnings;
}

/// True when saving should require an explicit confirmation.
bool needsConfirmation(List<TargetWarning> warnings) =>
    warnings.any((w) => w.level != SafetyLevel.info);
