import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/plan_view.dart';
import '../../core/i18n.dart';

/// Reusable meal plan templates (meal_plans with client_id = null).
class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key});

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() => db
      .from('meal_plans')
      .select('*, meal_plan_items(*)')
      .eq('dietitian_id', myId)
      .isFilter('client_id', null)
      .order('created_at', ascending: false);

  void _reload() => setState(() => _future = _load());

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final desc = TextEditingController();
    var period = 'weekly';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(t('New template')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, autofocus: true, decoration: InputDecoration(labelText: t('Name'))),
            TextField(controller: desc, decoration: InputDecoration(labelText: t('Description'))),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: [ButtonSegment(value: 'daily', label: Text(t('Daily'))), ButtonSegment(value: 'weekly', label: Text(t('Weekly')))],
              selected: {period},
              onSelectionChanged: (s) => set(() => period = s.first),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Create'))),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    await _run(() => db.from('meal_plans').insert({
          'dietitian_id': myId,
          'name': name.text.trim(),
          'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
          'period': period,
        }));
  }

  Future<void> _addItem(Map<String, dynamic> plan) async {
    var day = 0;
    var meal = 'breakfast';
    final title = TextEditingController();
    final details = TextEditingController();
    final kcal = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(t('Add meal')),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (plan['period'] == 'weekly')
                DropdownButtonFormField<int>(
                  initialValue: day,
                  decoration: InputDecoration(labelText: t('Day')),
                  items: [for (var i = 0; i < 7; i++) DropdownMenuItem(value: i, child: Text(weekdays[i]))],
                  onChanged: (v) => set(() => day = v!),
                ),
              DropdownButtonFormField<String>(
                initialValue: meal,
                decoration: InputDecoration(labelText: t('Meal')),
                items: [
                  DropdownMenuItem(value: 'breakfast', child: Text(t('Breakfast'))),
                  DropdownMenuItem(value: 'lunch', child: Text(t('Lunch'))),
                  DropdownMenuItem(value: 'dinner', child: Text(t('Dinner'))),
                  DropdownMenuItem(value: 'snack', child: Text(t('Snack'))),
                ],
                onChanged: (v) => set(() => meal = v!),
              ),
              TextField(controller: title, decoration: InputDecoration(labelText: t('What to eat'))),
              TextField(controller: details, decoration: InputDecoration(labelText: t('Details / portions'))),
              TextField(controller: kcal, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Calories'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Add'))),
          ],
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    await _run(() => db.from('meal_plan_items').insert({
          'plan_id': plan['id'],
          'day_index': day,
          'meal': meal,
          'title': title.text.trim(),
          'details': details.text.trim().isEmpty ? null : details.text.trim(),
          'calories': int.tryParse(kcal.text),
        }));
  }

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, plans) => ListView(padding: const EdgeInsets.all(16), children: [
        MaxWidth(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(t('Templates are copied when assigned, so editing one never changes plans clients already have.'))),
              const SizedBox(width: 12),
              FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: Text(t('New template'))),
            ]),
            const SizedBox(height: 12),
            if (plans.isEmpty) EmptyHint(t('No templates yet.')),
            for (final p in plans)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ExpansionTile(
                  title: Text(p['name'] as String),
                  subtitle: Text(t('{0} · {1} meals', [p['period'], (p['meal_plan_items'] as List).length])),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    PlanView(plan: p, onDeleteItem: (i) => _run(() => db.from('meal_plan_items').delete().eq('id', i['id']))),
                    Row(children: [
                      TextButton.icon(onPressed: () => _addItem(p), icon: const Icon(Icons.add), label: Text(t('Add meal'))),
                      const Spacer(),
                      TextButton(
                        onPressed: () async {
                          if (await confirm(context, t('Delete template?'), t('Plans already assigned to clients are not affected.'), ok: t('Delete'))) {
                            await _run(() => db.from('meal_plans').delete().eq('id', p['id']));
                          }
                        },
                        child: Text(t('Delete template')),
                      ),
                    ]),
                  ],
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}
