import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/session.dart';

/// Short, general habit tips picked from the onboarding answers (no numbers,
/// no medical advice). Shown on the plan page and, one a day, on Today.
class Tip {
  const Tip(this.icon, this.text);
  final IconData icon;
  final String text;
}

List<Tip> tipsFor({required List<String> challenges, String? goal, List<String> dietPreferences = const []}) {
  final tips = <Tip>[
    for (final c in challenges)
      ...switch (c) {
        'night_snacking' => [
            Tip(Icons.nights_stay_outlined, t('Make dinner filling with protein and vegetables, and decide on one evening snack in advance instead of grazing.')),
            Tip(Icons.no_food_outlined, t('Brush your teeth after dinner: it is a simple signal that eating is done for the day.')),
          ],
        'sweets' => [
            Tip(Icons.cake_outlined, t('Plan a small sweet after a meal rather than banning it; forbidden foods tend to win.')),
            Tip(Icons.apple, t('Keep fruit within reach for when a craving hits.')),
          ],
        'portions' => [
            Tip(Icons.restaurant, t('Serve on a smaller plate and fill half of it with vegetables first.')),
            Tip(Icons.timer_outlined, t('Eat slowly and wait a few minutes before a second helping.')),
          ],
        'irregular_meals' => [
            Tip(Icons.schedule, t('Set meal times that fit your day and let Nouri remind you.')),
            Tip(Icons.backpack_outlined, t('Keep an easy option with you (fruit, yogurt, a handful of nuts) for busy days.')),
          ],
        'low_water' => [
            Tip(Icons.water_drop_outlined, t('Drink a glass of water with every meal and keep a bottle on your desk.')),
          ],
        'eating_out' => [
            Tip(Icons.storefront_outlined, t('When eating out, choose grilled over fried and ask for sauces on the side.')),
          ],
        'emotional_eating' => [
            Tip(Icons.self_improvement, t('Before reaching for food, pause and ask: am I hungry, or tired, stressed or bored?')),
          ],
        _ => const <Tip>[],
      },
    if (goal == 'lose') Tip(Icons.trending_down, t('Log meals right after eating; small, steady changes beat strict rules.')),
    if (goal == 'gain') Tip(Icons.trending_up, t('Add an extra snack between meals rather than forcing very large portions.')),
    if (goal == 'healthy') Tip(Icons.eco_outlined, t('Aim for a vegetable or fruit at every meal.')),
    if (dietPreferences.contains('vegan') || dietPreferences.contains('vegetarian'))
      Tip(Icons.grass, t('Combine legumes, grains, eggs or dairy through the day to get enough protein.')),
  ];
  return tips;
}

/// "For you" card on the Today screen: one tip a day from the client's answers.
class PersonalTipCard extends StatefulWidget {
  const PersonalTipCard({super.key});

  @override
  State<PersonalTipCard> createState() => _PersonalTipCardState();
}

class _PersonalTipCardState extends State<PersonalTipCard> {
  Tip? _tip;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await db.from('profiles').select('goal, challenges, diet_preferences').eq('id', myId).single();
      final tips = tipsFor(
        challenges: [for (final c in p['challenges'] as List? ?? const []) c as String],
        goal: p['goal'] as String?,
        dietPreferences: [for (final c in p['diet_preferences'] as List? ?? const []) c as String],
      );
      if (tips.isEmpty || !mounted) return;
      final day = DateTime.now().difference(DateTime(2026)).inDays;
      setState(() => _tip = tips[day % tips.length]);
    } catch (_) {
      // Just no card.
    }
  }

  @override
  Widget build(BuildContext context) {
    final tip = _tip;
    if (tip == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(tip.icon, color: scheme.onSecondaryContainer),
        title: Text(t('Tip for you'), style: Theme.of(context).textTheme.labelLarge),
        subtitle: Text(tip.text),
      ),
    );
  }
}
