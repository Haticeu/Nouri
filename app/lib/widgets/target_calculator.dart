import 'package:flutter/material.dart';

import '../core/goal_calculator.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../core/i18n.dart';

/// "Calculate my targets" for people without a dietitian. Pre-fills from the
/// profile and latest weigh-in; saves targets (and missing profile details).
/// Returns true when targets were saved.
Future<bool> showTargetCalculator(BuildContext context) async {
  final profile = await db.from('profiles').select('birth_date, height_cm, sex').eq('id', myId).single();
  final weights = await db.from('weight_entries').select('weight_kg').eq('client_id', myId).order('measured_on', ascending: false).limit(1);
  if (!context.mounted) return false;
  final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _CalculatorScreen(profile: profile, latestKg: weights.isEmpty ? null : asNum(weights.first['weight_kg'])),
  ));
  return saved ?? false;
}

class _CalculatorScreen extends StatefulWidget {
  const _CalculatorScreen({required this.profile, required this.latestKg});
  final Map<String, dynamic> profile;
  final num? latestKg;

  @override
  State<_CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<_CalculatorScreen> {
  late Sex _sex = switch (widget.profile['sex']) { 'male' => Sex.male, 'other' => Sex.other, _ => Sex.female };
  late final _age = TextEditingController(text: _ageFromProfile()?.toString() ?? '');
  late final _height = TextEditingController(text: asNum(widget.profile['height_cm'])?.toString() ?? '');
  late final _weight = TextEditingController(text: widget.latestKg?.toString() ?? '');
  Activity _activity = Activity.light;
  Goal _goal = Goal.maintain;
  bool _saving = false;

  int? _ageFromProfile() {
    final b = widget.profile['birth_date'] as String?;
    if (b == null) return null;
    return (DateTime.now().difference(DateTime.parse(b)).inDays / 365.25).floor();
  }

  double? _num(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  TargetPlan? get _plan {
    final age = _num(_age);
    final h = _num(_height);
    final w = _num(_weight);
    if (age == null || h == null || w == null || age < 16 || age > 100 || h < 120 || h > 230 || w < 35 || w > 300) return null;
    return calculateTargets(sex: _sex, age: age.round(), heightCm: h, weightKg: w, activity: _activity, goal: _goal);
  }

  Future<void> _save(TargetPlan p) async {
    setState(() => _saving = true);
    try {
      await db.from('nutrition_targets').upsert({
        'client_id': myId,
        'calories': p.calories,
        'protein_g': p.proteinG,
        'carbs_g': p.carbsG,
        'fat_g': p.fatG,
        'water_ml': p.waterMl,
      });
      // Keep the profile in step so the dietitian side (if one joins later) sees it.
      await db.from('profiles').update({'height_cm': _num(_height), 'sex': _sex.name}).eq('id', myId);
      if (widget.latestKg == null) {
        await db.from('weight_entries').insert({'client_id': myId, 'measured_on': today(), 'weight_kg': _num(_weight)});
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final plan = _plan;
    void changed(_) => setState(() {});

    return Scaffold(
      appBar: AppBar(title: Text(t('Your daily targets'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        MaxWidth(
          width: 560,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t('Tell us a little about you and we\'ll suggest calorie, macro and water targets. You can fine-tune them any time.'),
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            SegmentedButton<Sex>(
              segments: [
                ButtonSegment(value: Sex.female, label: Text(t('Female'))),
                ButtonSegment(value: Sex.male, label: Text(t('Male'))),
                ButtonSegment(value: Sex.other, label: Text(t('Other'))),
              ],
              selected: {_sex},
              onSelectionChanged: (s) => setState(() => _sex = s.first),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: _age, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Age')), onChanged: changed)),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _height, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Height'), suffixText: 'cm'), onChanged: changed)),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _weight, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: t('Weight'), suffixText: 'kg'), onChanged: changed)),
            ]),
            const SizedBox(height: 18),
            Text(t('How active are you?'), style: text.titleMedium),
            const SizedBox(height: 6),
            RadioGroup<Activity>(
              groupValue: _activity,
              onChanged: (v) => setState(() => _activity = v ?? _activity),
              child: Column(children: [
                for (final a in Activity.values)
                  RadioListTile<Activity>(
                    contentPadding: EdgeInsets.zero,
                    value: a,
                    title: Text(t(a.label)),
                    subtitle: Text(t(a.hint)),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            Text(t('Your goal'), style: text.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final g in Goal.values)
                ChoiceChip(
                  label: Text(t(g.label)),
                  selected: _goal == g,
                  onSelected: (_) => setState(() => _goal = g),
                ),
            ]),
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(t(_goal.hint), style: TextStyle(color: scheme.onSurfaceVariant))),
            const SizedBox(height: 18),
            if (plan == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(t('Enter your age, height and weight to see your targets.'), style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              )
            else
              _result(plan),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: plan == null || _saving ? null : () => _save(plan),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
            child: Text(t('Use these targets')),
          ),
        ),
      ),
    );
  }

  Widget _result(TargetPlan p) {
    final c = context.nouri;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget stat(String label, String value, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
            child: Column(children: [
              Text(value, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              Text(label, style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
            ]),
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('Suggested daily target'), style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
          Text(t('{0} kcal', [p.calories]), style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: c.link)),
          Text(t('Your body uses about {0} kcal a day at this activity level ({1} at rest).', [p.maintenance, p.bmr]),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Row(children: [
            stat(t('Protein'), '${p.proteinG} g', c.protein),
            const SizedBox(width: 8),
            stat(t('Carbs'), '${p.carbsG} g', c.carbs),
            const SizedBox(width: 8),
            stat(t('Fat'), '${p.fatG} g', c.fat),
            const SizedBox(width: 8),
            stat(t('Water'), '${(p.waterMl / 1000).toStringAsFixed(p.waterMl % 1000 == 0 ? 0 : 2).replaceFirst(RegExp(r'0$'), '')} L', c.water),
          ]),
          if (p.raisedToMinimum) ...[
            const SizedBox(height: 12),
            Text(
              t('Raised to 1200 kcal, the usual minimum without medical supervision. For a lower target, please work with a dietitian.'),
              style: text.bodySmall?.copyWith(color: scheme.error, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 10),
          Text(t('These are general estimates, not medical advice.'), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
