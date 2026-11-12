import 'package:flutter/material.dart';

import '../core/ui.dart';
import '../core/i18n.dart';

final weekdays = [t('Monday'), t('Tuesday'), t('Wednesday'), t('Thursday'), t('Friday'), t('Saturday'), t('Sunday')];
const _mealOrder = {'breakfast': 0, 'lunch': 1, 'dinner': 2, 'snack': 3};

/// Meal plan items grouped by day. [plan] is a meal_plans row with
/// `meal_plan_items` embedded.
class PlanView extends StatelessWidget {
  const PlanView({super.key, required this.plan, this.onDeleteItem});
  final Map<String, dynamic> plan;
  final void Function(Map<String, dynamic> item)? onDeleteItem;

  @override
  Widget build(BuildContext context) {
    final items = List<Map<String, dynamic>>.from(plan['meal_plan_items'] as List? ?? const [])
      ..sort((a, b) {
        final d = (a['day_index'] as int).compareTo(b['day_index'] as int);
        if (d != 0) return d;
        return _mealOrder[a['meal']]!.compareTo(_mealOrder[b['meal']]!);
      });
    final daily = plan['period'] == 'daily';
    final days = items.map((i) => i['day_index'] as int).toSet().toList()..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if ((plan['description'] as String?)?.isNotEmpty ?? false)
        Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(plan['description'] as String)),
      if (items.isEmpty) EmptyHint(t('No meals in this plan yet.')),
      for (final day in days) ...[
        if (!daily)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(weekdays[day], style: Theme.of(context).textTheme.labelLarge),
          ),
        for (final i in items.where((i) => i['day_index'] == day))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(width: 72, child: Text(t(cap(i['meal'] as String)))),
            title: Text(i['title'] as String),
            subtitle: Text([
              if ((i['details'] as String?)?.isNotEmpty ?? false) i['details'],
              if (i['calories'] != null) '${i['calories']} kcal',
            ].join(' · ')),
            trailing: onDeleteItem == null
                ? null
                : IconButton(icon: const Icon(Icons.close), onPressed: () => onDeleteItem!(i)),
          ),
      ],
    ]);
  }
}
