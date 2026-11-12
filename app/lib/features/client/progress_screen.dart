import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../widgets/weight_chart.dart';
import '../../core/i18n.dart';

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  late Future<_ProgressData> _future = _load();

  Future<_ProgressData> _load() async {
    final weekStart = isoDate.format(DateTime.now().subtract(const Duration(days: 6)));
    final r = await Future.wait([
      db.from('weight_entries').select().eq('client_id', myId).order('measured_on', ascending: false),
      db.from('food_entries').select('logged_on, calories, protein_g').eq('client_id', myId).gte('logged_on', weekStart),
      db.from('water_entries').select('logged_on, amount_ml').eq('client_id', myId).gte('logged_on', weekStart),
      db.from('nutrition_targets').select().eq('client_id', myId).maybeSingle(),
    ]);
    return _ProgressData(
      weights: List<Map<String, dynamic>>.from(r[0] as List),
      food: List<Map<String, dynamic>>.from(r[1] as List),
      water: List<Map<String, dynamic>>.from(r[2] as List),
      targets: r[3] as Map<String, dynamic>?,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader<_ProgressData>(
      future: _future,
      builder: (context, d) => RefreshIndicator(
        onRefresh: () async => setState(() => _future = _load()),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          MaxWidth(
            width: 640,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _WeekSummary(d),
              const SizedBox(height: 12),
              SectionCard(
                title: t('Weight'),
                action: FilledButton.tonalIcon(onPressed: _addWeight, icon: const Icon(Icons.add), label: Text(t('Log weight'))),
                child: WeightChart(entries: d.weights),
              ),
              SectionCard(
                title: t('History'),
                child: Column(children: [
                  if (d.weights.isEmpty) EmptyHint(t('No weigh-ins yet.')),
                  for (final r in d.weights.take(20))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(t('{0} kg', [asNum(r['weight_kg'])])),
                      subtitle: Text(dateFmt.format(DateTime.parse(r['measured_on'] as String))),
                    ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _addWeight() async {
    final v = await promptText(context, t('Weight (kg)'), hint: 'e.g. 72.4');
    final kg = num.tryParse((v ?? '').replaceAll(',', '.'));
    if (kg == null) return;
    try {
      await db.from('weight_entries').insert({'client_id': myId, 'measured_on': today(), 'weight_kg': kg});
      setState(() => _future = _load());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

class _ProgressData {
  _ProgressData({required this.weights, required this.food, required this.water, required this.targets});
  final List<Map<String, dynamic>> weights; // newest first
  final List<Map<String, dynamic>> food; // last 7 days
  final List<Map<String, dynamic>> water; // last 7 days
  final Map<String, dynamic>? targets;
}

/// The last 7 days at a glance: consistency, averages and weight trend.
class _WeekSummary extends StatelessWidget {
  const _WeekSummary(this.d);
  final _ProgressData d;

  @override
  Widget build(BuildContext context) {
    final c = context.nouri;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final days = {for (final f in d.food) f['logged_on'] as String};
    final logged = days.length;
    num sum(String k) => d.food.fold<num>(0, (s, f) => s + (asNum(f[k]) ?? 0));
    final avgKcal = logged == 0 ? null : sum('calories') / logged;
    final avgProtein = logged == 0 ? null : sum('protein_g') / logged;
    final avgWater = d.water.fold<int>(0, (s, w) => s + (w['amount_ml'] as int)) / 7;
    final target = d.targets?['calories'] as int?;

    // Weight change over the last 30 days (newest vs oldest in that window).
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final recent = d.weights.where((w) => DateTime.parse(w['measured_on'] as String).isAfter(cutoff)).toList();
    final change = recent.length < 2 ? null : asNum(recent.first['weight_kg'])! - asNum(recent.last['weight_kg'])!;

    // Dots for the last 7 days, oldest first.
    final week = [for (var i = 6; i >= 0; i--) isoDate.format(DateTime.now().subtract(Duration(days: i)))];

    Widget tile(String label, String value, String? sub, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(value, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              if (sub != null) Text(sub, style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
            ]),
          ),
        );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('This week'), style: text.titleLarge),
          const SizedBox(height: 10),
          Row(children: [
            for (final day in week) ...[
              Expanded(
                child: Column(children: [
                  Container(
                    height: 30,
                    decoration: BoxDecoration(
                      color: days.contains(day) ? scheme.primary : c.track,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: days.contains(day) ? Icon(Icons.check_rounded, size: 18, color: scheme.onPrimary) : null,
                  ),
                  const SizedBox(height: 4),
                  Text(DateFormat.E().format(DateTime.parse(day)),
                      style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (day != week.last) const SizedBox(width: 6),
            ],
          ]),
          const SizedBox(height: 6),
          Text(t('Logged {0} of 7 days', [logged]), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(children: [
            tile(t('Avg calories'), avgKcal == null ? '–' : '${avgKcal.round()}', target == null ? t('per logged day') : t('goal {0}', [target]), c.protein),
            const SizedBox(width: 8),
            tile(t('Avg protein'), avgProtein == null ? '–' : '${avgProtein.round()} g',
                d.targets?['protein_g'] == null ? null : t('goal {0} g', [d.targets!['protein_g']]), c.fat),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            tile(t('Avg water'), '${(avgWater / 1000).toStringAsFixed(1)} L', t('per day'), c.water),
            const SizedBox(width: 8),
            tile(t('Weight, 30 days'), change == null ? '–' : '${change > 0 ? '+' : ''}${change.toStringAsFixed(1)} kg',
                change == null ? t('log 2 weigh-ins') : null, c.carbs),
          ]),
        ]),
      ),
    );
  }
}
