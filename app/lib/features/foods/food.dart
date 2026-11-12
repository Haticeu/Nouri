import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/session.dart';
import '../../core/ui.dart';

/// One household measure of a food: "1 su bardağı = 206 g".
class Portion {
  const Portion({required this.unit, this.size, required this.grams, this.source});
  final String unit; // adet, dilim, su bardağı, ... (see portion_units.unit)
  final String? size; // küçük / orta / büyük
  final double grams;
  final String? source;

  factory Portion.fromJson(Map<String, dynamic> j) => Portion(
        unit: j['unit'] as String,
        size: j['size'] as String?,
        grams: (asNum(j['grams']) ?? 0).toDouble(),
        source: j['source'] as String?,
      );

  Map<String, dynamic> toJson() => {'unit': unit, 'size': size, 'grams': grams};

  String get label => unitLabel(unit, size);
}

/// A row of the foods table (as returned by search_foods / get_food).
/// All nutrition is per 100 g and comes from the row's source.
class Food {
  Food(this.json)
      : portions = [
          for (final p in (json['portions'] as List? ?? const [])) Portion.fromJson(Map<String, dynamic>.from(p as Map)),
        ];
  /// From a `foods` row selected with `portion_units(...)` embedded.
  factory Food.fromRow(Map<String, dynamic> row) {
    final units = [for (final u in (row['portion_units'] as List? ?? const [])) Map<String, dynamic>.from(u as Map)]
      ..sort((a, b) => (asNum(a['sort']) ?? 0).compareTo(asNum(b['sort']) ?? 0));
    return Food({
      ...row..remove('portion_units'),
      'portions': [for (final u in units) {'unit': u['unit'], 'size': u['size'], 'grams': u['grams_per_unit'], 'source': u['source']}],
    });
  }

  static const rowSelect = '*, portion_units(unit, size, grams_per_unit, source, sort)';

  final Map<String, dynamic> json;
  final List<Portion> portions;

  String get id => json['id'] as String;
  String get nameTr => json['name_tr'] as String;
  String get nameEn => json['name_en'] as String;
  String get name => appLang == 'tr' ? nameTr : nameEn;
  String? get brand => json['brand'] as String?;
  String? get barcode => json['barcode'] as String?;
  String get source => json['source'] as String;
  String? get sourceRef => json['source_ref'] as String?;
  String? get sourceNote => json['source_note'] as String?;
  bool get verified => json['verified'] == true;
  bool get isLiquid => json['is_liquid'] == true;
  bool get hasValues => source != 'todo' && json['kcal_per_100g'] != null;

  double? per100(String key) => asNum(json['${key}_per_100g'])?.toDouble();

  /// Calories and macros for [grams] of this food (null if it has no values yet).
  Nutrition? nutrition(double grams) {
    if (!hasValues) return null;
    final x = grams / 100;
    return Nutrition(
      calories: per100('kcal')! * x,
      protein: per100('protein')! * x,
      carbs: per100('carbs')! * x,
      fat: per100('fat')! * x,
    );
  }

  /// Grams for [amount] of [unit] ('gram' is direct), or null if the food has no such measure.
  double? gramsFor(String unit, String? size, double amount) {
    if (unit == 'gram') return amount;
    final options = portions.where((p) => p.unit == unit).toList();
    if (options.isEmpty) return null;
    final p = options.firstWhere((o) => o.size == size,
        orElse: () => options.firstWhere((o) => o.size == 'orta', orElse: () => options.first));
    return amount * p.grams;
  }
}

class Nutrition {
  const Nutrition({required this.calories, required this.protein, required this.carbs, required this.fat});
  final double calories, protein, carbs, fat;

  Nutrition operator +(Nutrition o) =>
      Nutrition(calories: calories + o.calories, protein: protein + o.protein, carbs: carbs + o.carbs, fat: fat + o.fat);
  static const zero = Nutrition(calories: 0, protein: 0, carbs: 0, fat: 0);
}

/// Turkish household measures are stored in Turkish; English names for the English UI.
const _unitEn = {
  'gram': 'g',
  'ml': 'ml',
  'adet': 'piece',
  'dilim': 'slice',
  'su bardağı': 'glass (200 ml)',
  'çay bardağı': 'tea glass (100 ml)',
  'yemek kaşığı': 'tablespoon',
  'tatlı kaşığı': 'dessert spoon',
  'çay kaşığı': 'teaspoon',
  'kase': 'bowl',
  'kepçe': 'ladle',
  'porsiyon': 'portion',
  'avuç': 'handful',
  'paket': 'package',
};
const _sizeEn = {'küçük': 'small', 'orta': 'medium', 'büyük': 'large'};
const allUnits = ['adet', 'dilim', 'su bardağı', 'çay bardağı', 'yemek kaşığı', 'tatlı kaşığı', 'çay kaşığı', 'kase', 'kepçe', 'porsiyon', 'avuç', 'ml', 'paket'];
const allSizes = ['küçük', 'orta', 'büyük'];

String unitLabel(String unit, [String? size]) {
  if (appLang == 'tr') {
    final u = unit == 'gram' ? 'gram' : unit;
    return size == null ? u : '$u ($size)';
  }
  final u = _unitEn[unit] ?? unit;
  return size == null ? u : '${_sizeEn[size] ?? size} $u';
}

/// Typo-tolerant search (Turkish and English names, aliases, brands).
Future<List<Food>> searchFoods(String query, {int limit = 20}) async {
  if (query.trim().length < 2) return [];
  final rows = await db.rpc('search_foods', params: {'p_query': query.trim(), 'p_limit': limit}) as List;
  return [for (final r in rows) Food(Map<String, dynamic>.from(r as Map))];
}

Future<Food?> getFood(String id) async {
  final r = await db.rpc('get_food', params: {'p_food': id});
  return r == null ? null : Food(Map<String, dynamic>.from(r as Map));
}

/// Barcode -> food via the lookup-barcode function (Open Food Facts, cached).
Future<({Food? food, String? reason, String? name})> lookupBarcode(String barcode) async {
  final res = await db.functions.invoke('lookup-barcode', body: {'barcode': barcode.trim()});
  final m = Map<String, dynamic>.from(res.data as Map);
  if (m['found'] == true) return (food: Food(Map<String, dynamic>.from(m['food'] as Map)), reason: null, name: null);
  return (food: null, reason: m['reason'] as String?, name: m['name'] as String?);
}

/// Where a food's numbers come from, as a small chip: Verified / USDA / Open Food Facts / Dietitian / No values yet.
class FoodSourceChip extends StatelessWidget {
  const FoodSourceChip(this.food, {super.key});
  final Food food;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label, Color color) = food.verified
        ? (Icons.verified, t('Verified'), scheme.primary)
        : switch (food.source) {
            'usda_fdc' => (Icons.public, 'USDA', scheme.secondary),
            'open_food_facts' => (Icons.qr_code_2, 'Open Food Facts', scheme.secondary),
            'dietitian' => (Icons.person_outline, t('Dietitian'), scheme.secondary),
            _ => (Icons.hourglass_empty, t('No values yet'), scheme.error),
          };
    return Tooltip(
      message: [
        if (food.verified) t('Checked by a dietitian'),
        ?food.sourceRef,
        ?food.sourceNote,
      ].join('\n'),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
