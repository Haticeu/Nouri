import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/session.dart';
import '../../core/ui.dart';
import 'food.dart';
import 'food_picker.dart';

/// One line of a meal being logged: a food from the database plus an amount
/// in a household measure. Nutrition = the food's per-100 g values × grams.
///
/// [LogItem.estimate] is for an estimate that has no food behind it (AI photo
/// analysis, behind kAiEnabled): its values scale with the grams the user enters.
class LogItem {
  LogItem.food(Food this.food, {String? unit, String? size, double? amount, this.confidence, this.question, this.note, this.aiRaw})
      : unit = unit ?? defaultUnit(food),
        size = sizeFor(food, unit ?? defaultUnit(food), size),
        // Grams-only foods start at 100 g, anything else at 1 measure.
        amount = TextEditingController(text: _initialAmount(amount, unit ?? defaultUnit(food))),
        name = TextEditingController(text: food.name),
        _estimate = null;

  /// The size actually used: as asked if the food has it, else medium, else the first one.
  static String? sizeFor(Food f, String unit, String? size) {
    final sizes = f.portions.where((p) => p.unit == unit).map((p) => p.size).toList();
    if (sizes.isEmpty || sizes.contains(size)) return size;
    return sizes.contains('orta') ? 'orta' : sizes.first;
  }

  LogItem.estimate(Map<String, dynamic> m)
      : food = null,
        unit = 'gram',
        size = null,
        amount = TextEditingController(text: '${m['grams'] ?? ''}'),
        name = TextEditingController(text: m['name'] as String? ?? ''),
        confidence = m['confidence'] as String?,
        question = null,
        note = m['portion'] as String?,
        aiRaw = null,
        _estimate = (
          grams: (asNum(m['grams']) ?? 0).toDouble(),
          n: Nutrition(
            calories: (asNum(m['calories']) ?? 0).toDouble(),
            protein: (asNum(m['protein_g']) ?? 0).toDouble(),
            carbs: (asNum(m['carbs_g']) ?? 0).toDouble(),
            fat: (asNum(m['fat_g']) ?? 0).toDouble(),
          ),
        );

  /// From an estimate-meal item ({food, unit, size, amount, grams, question, ...}).
  factory LogItem.fromEstimate(Map<String, dynamic> m) {
    if (m['food'] == null) return LogItem.estimate(m);
    final food = Food(Map<String, dynamic>.from(m['food'] as Map));
    final grams = asNum(m['grams'])?.toDouble();
    return LogItem.food(
      food,
      unit: grams == null ? defaultUnit(food) : m['unit'] as String?,
      size: grams == null ? null : m['size'] as String?,
      amount: grams == null ? 0 : (asNum(m['amount']) ?? 1).toDouble(),
      confidence: m['confidence'] as String?,
      question: m['question'] as String?,
      note: m['text'] as String?,
    );
  }

  Food? food;
  String unit;
  String? size;
  final TextEditingController amount;
  final TextEditingController name;
  final String? confidence;
  String? question;
  final String? note;
  final ({double grams, Nutrition n})? _estimate;
  /// What a recogniser suggested (stored with the entry, never used for values).
  final Map<String, dynamic>? aiRaw;

  static String _fmt(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  static String _initialAmount(double? amount, String unit) {
    final a = amount ?? (unit == 'gram' ? 100 : 1);
    return a > 0 ? _fmt(a) : '';
  }

  /// Most natural measure for a food: a portion, a piece, a slice, a glass, a spoon, else grams.
  static String defaultUnit(Food f) {
    // Packaged products: the whole package is the usual amount.
    for (final u in ['paket', 'porsiyon', 'adet', 'dilim', f.isLiquid ? 'su bardağı' : 'yemek kaşığı', 'su bardağı']) {
      if (f.portions.any((p) => p.unit == u)) return u;
    }
    return 'gram';
  }

  double? get amountValue {
    final v = double.tryParse(amount.text.replaceAll(',', '.'));
    return v == null || v <= 0 ? null : v;
  }

  double? get grams {
    final a = amountValue;
    if (a == null) return null;
    if (food == null) return a; // estimate: amount is grams
    return food!.gramsFor(unit, size, a);
  }

  Nutrition? get nutrition {
    final g = grams;
    if (g == null) return null;
    if (food == null) {
      final e = _estimate!;
      final x = e.grams > 0 ? g / e.grams : 1.0;
      return Nutrition(calories: e.n.calories * x, protein: e.n.protein * x, carbs: e.n.carbs * x, fat: e.n.fat * x);
    }
    return food!.nutrition(g);
  }

  bool get ready => nutrition != null;

  /// Measures the user can pick for this food: its portions, plus grams.
  List<(String, String?)> get measures => [
        if (food != null) ...{for (final p in food!.portions) (p.unit, p.size)},
        ('gram', null),
      ];

  Map<String, dynamic> toEntry({required String slot, required String day, required String source, String? photoPath}) {
    final n = nutrition!;
    return {
      'client_id': myId,
      'logged_on': day,
      'meal': slot,
      'name': name.text.trim().isEmpty ? (food?.name ?? t('Food')) : name.text.trim(),
      'calories': n.calories.round(),
      'protein_g': double.parse(n.protein.toStringAsFixed(1)),
      'carbs_g': double.parse(n.carbs.toStringAsFixed(1)),
      'fat_g': double.parse(n.fat.toStringAsFixed(1)),
      'food_id': food?.id,
      'portion_unit': food == null ? 'gram' : (size == null ? unit : '$unit ($size)'),
      'portion_amount': amountValue,
      'grams': double.parse(grams!.toStringAsFixed(1)),
      'source': source,
      'photo_path': ?photoPath,
      'ai_raw': ?aiRaw,
    };
  }
}

/// Confirm and correct a meal before it is logged. Returns true if saved.
///   source: 'manual' (search), 'text' (description), 'barcode', 'photo'
Future<bool> reviewMeal(
  BuildContext context, {
  required List<LogItem> items,
  required String slot,
  required String day,
  required String source,
  String? notes,
  Uint8List? photo,
  String? photoPath,
}) async =>
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MealReview(items: items, slot: slot, day: day, source: source, notes: notes, photo: photo, photoPath: photoPath),
    )) ??
    false;

class MealReview extends StatefulWidget {
  const MealReview({
    super.key,
    required this.items,
    required this.slot,
    required this.day,
    required this.source,
    this.notes,
    this.photo,
    this.photoPath,
  });
  final List<LogItem> items;
  final String slot;
  final String day;
  final String source;
  final String? notes;
  final Uint8List? photo;
  final String? photoPath;

  @override
  State<MealReview> createState() => _MealReviewState();
}

class _MealReviewState extends State<MealReview> {
  late final List<LogItem> _items = [...widget.items];
  bool _saving = false;

  Future<void> _addFood() async {
    final f = await pickFood(context);
    if (f != null) setState(() => _items.add(LogItem.food(f)));
  }

  Future<void> _changeFood(LogItem i) async {
    final f = await pickFood(context, initialQuery: i.food?.nameTr ?? i.name.text);
    if (f == null) return;
    setState(() {
      i.food = f;
      i.name.text = f.name;
      i.question = null;
      if (!f.portions.any((p) => p.unit == i.unit)) i.unit = LogItem.defaultUnit(f);
      i.size = LogItem.sizeFor(f, i.unit, i.size);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await db.from('food_entries').insert([
        for (final i in _items) i.toEntry(slot: widget.slot, day: widget.day, source: widget.source, photoPath: widget.photoPath),
      ]);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = _items.fold<Nutrition>(Nutrition.zero, (s, i) => s + (i.nutrition ?? Nutrition.zero));
    final blocked = _items.where((i) => !i.ready).length;
    return Scaffold(
      appBar: AppBar(title: Text(t('Check your meal'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        MaxWidth(
          width: 640,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.photo != null) ...[
              ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(widget.photo!, height: 220, fit: BoxFit.cover)),
              const SizedBox(height: 12),
            ],
            if (_items.isEmpty)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.no_food_outlined),
                  title: Text(t('No food recognised')),
                  subtitle: Text(widget.notes?.isNotEmpty == true ? widget.notes! : t('Search for the food instead.')),
                ),
              )
            else ...[
              Text(t('{0} kcal', [total.calories.round()]), style: text.headlineSmall),
              Text(
                t('P {0} g · C {1} g · F {2} g', [total.protein.toStringAsFixed(1), total.carbs.toStringAsFixed(1), total.fat.toStringAsFixed(1)]),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                t('Values come from Nouri\'s food database (USDA FoodData Central, Open Food Facts and dietitians). Change the amount or the measure and everything updates.'),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (widget.notes?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(widget.notes!)),
                ]),
              ],
              const SizedBox(height: 12),
              for (final i in _items) _card(i),
            ],
            const SizedBox(height: 4),
            OutlinedButton.icon(onPressed: _addFood, icon: const Icon(Icons.add), label: Text(t('Add another food'))),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (blocked > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(t('Complete or remove the items marked in red to log this meal.'),
                    style: TextStyle(color: scheme.error), textAlign: TextAlign.center),
              ),
            FilledButton.icon(
              onPressed: _saving || _items.isEmpty || blocked > 0 ? null : _save,
              icon: const Icon(Icons.check),
              label: Text(_items.length == 1
                  ? t('Log 1 item to {0}', [mealName(widget.slot)])
                  : t('Log {0} items to {1}', [_items.length, mealName(widget.slot)])),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _card(LogItem i) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final n = i.nutrition;
    final g = i.grams;
    final food = i.food;
    final problem = food != null && !food.hasValues
        ? t('No nutrition values for this food yet. Pick a similar food or remove it.')
        : g == null
            ? (i.question ?? t('Enter how much you had.'))
            : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: problem == null
          ? null
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: scheme.error)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(food?.name ?? i.name.text, style: text.titleMedium),
                const SizedBox(height: 2),
                if (food != null) FoodSourceChip(food) else Text(t('Estimate'), style: text.labelSmall),
              ]),
            ),
            TextButton(onPressed: () => _changeFood(i), child: Text(food == null ? t('Find food') : t('Change'))),
            IconButton(tooltip: t('Remove'), onPressed: () => setState(() => _items.remove(i)), icon: const Icon(Icons.close)),
          ]),
          if (i.note != null && i.note!.isNotEmpty)
            Text('“${i.note}”', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 92,
              child: TextField(
                controller: i.amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: t('Amount'), isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<(String, String?)>(
                // initialValue is read once; a new key shows a measure changed from outside.
                key: ValueKey((food?.id, food?.portions.length, i.unit, i.size)),
                initialValue: i.measures.contains((i.unit, i.size))
                    ? (i.unit, i.size)
                    : i.measures.firstWhere((m) => m.$1 == i.unit, orElse: () => i.measures.last),
                isExpanded: true,
                decoration: InputDecoration(labelText: t('Measure'), isDense: true),
                items: [
                  for (final m in i.measures)
                    DropdownMenuItem(
                      value: m,
                      child: Text(m.$1 == 'gram' ? unitLabel('gram') : _measureLabel(food, m), overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (m) => setState(() {
                  if (m == null) return;
                  // Switching to grams: keep the same amount of food.
                  if (m.$1 == 'gram' && i.unit != 'gram' && g != null) i.amount.text = '${g.round()}';
                  i.unit = m.$1;
                  i.size = m.$2;
                }),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          if (n != null)
            Text(
              t('{0} g · {1} kcal · P {2} g · C {3} g · F {4} g', [
                g!.round(),
                n.calories.round(),
                n.protein.toStringAsFixed(1),
                n.carbs.toStringAsFixed(1),
                n.fat.toStringAsFixed(1),
              ]),
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          if (food?.barcode != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                onPressed: () => _fixPackage(i),
                icon: const Icon(Icons.scale_outlined, size: 18),
                label: Text(food!.portions.any((p) => p.unit == 'paket')
                    ? t('Package weight wrong? Fix it')
                    : t('Add the package weight')),
              ),
            ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.help_outline, size: 18, color: scheme.error),
                const SizedBox(width: 6),
                Expanded(child: Text(tServer(problem), style: TextStyle(color: scheme.error))),
              ]),
            )
          else if (i.confidence == 'medium')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(t('Amount assumed: check it'), style: text.labelMedium?.copyWith(color: scheme.tertiary)),
            ),
        ]),
      ),
    );
  }

  /// Packaged product: set how many grams one package is, as printed on the
  /// label. Only the package size changes; nutrition values stay the label's.
  Future<void> _fixPackage(LogItem i) async {
    final food = i.food!;
    final current = food.portions.where((p) => p.unit == 'paket').firstOrNull?.grams;
    final v = await promptText(
      context,
      t('Package weight'),
      hint: t('Net weight on the package, in grams (e.g. 52)'),
      initial: current == null ? '' : '${current.round()}',
      ok: t('Save'),
    );
    final grams = double.tryParse((v ?? '').replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.]'), ''));
    if (grams == null || !mounted) return;
    try {
      final json = await db.rpc('set_package_size', params: {'p_food': food.id, 'p_grams': grams});
      final updated = Food(Map<String, dynamic>.from(json as Map));
      setState(() {
        i.food = updated;
        i.unit = 'paket';
        i.size = null;
        i.amount.text = '1';
      });
      if (mounted) showInfo(context, t('Saved: 1 package = {0} g. Thanks, this helps everyone who scans it.', [grams.round()]));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  String _measureLabel(Food? food, (String, String?) m) {
    final p = food?.portions.where((p) => p.unit == m.$1 && p.size == m.$2).firstOrNull;
    return p == null ? unitLabel(m.$1, m.$2) : '${unitLabel(m.$1, m.$2)} · ${p.grams.round()} g';
  }
}
