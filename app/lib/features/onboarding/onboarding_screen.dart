import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/goal_calculator.dart';
import '../../core/i18n.dart';
import '../../core/reminders.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import 'personal_tips.dart';

/// First-run questions for clients. A few short steps get to know the person
/// (goal, body, activity, eating style, allergies, health, habits), then show
/// a personal plan: daily targets, a rough timeline and tips for their
/// challenges. Everything is saved on their profile; a linked dietitian can
/// read it (listed on the consent screen).
///
/// [redo]: opened again from the profile; prefilled, and closes instead of
/// going home.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.session, this.redo = false});
  final AppSession session;
  final bool redo;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, goal, body, target, activity, eating, health, habits, dietitian, reminders, plan }

const _diets = ['vegetarian', 'vegan', 'pescatarian', 'gluten_free', 'lactose_free', 'halal'];
const _allergyList = ['nuts', 'peanuts', 'milk', 'egg', 'gluten', 'seafood', 'soy', 'sesame'];
const _healthList = ['pregnant', 'diabetes', 'kidney', 'eating_disorder', 'other'];
const _challengeList = ['night_snacking', 'sweets', 'portions', 'irregular_meals', 'low_water', 'eating_out', 'emotional_eating'];

/// Display name for a stored onboarding answer (also used on the dietitian side).
String onboardingLabel(String key) => _label(key);

String _label(String key) => t(switch (key) {
      'goal_lose' => 'Lose weight',
      'goal_maintain' => 'Maintain my weight',
      'goal_gain' => 'Gain weight',
      'goal_healthy' => 'Eat healthier',
      'activity_sedentary' => 'Mostly sitting',
      'activity_light' => 'Lightly active',
      'activity_moderate' => 'Moderately active',
      'activity_active' => 'Very active',
      'activity_athlete' => 'Athlete',
      'under_18' => 'Under 18',
      'vegetarian' => 'Vegetarian',
      'vegan' => 'Vegan',
      'pescatarian' => 'Pescatarian',
      'gluten_free' => 'Gluten-free',
      'lactose_free' => 'Lactose-free',
      'halal' => 'Halal',
      'nuts' => 'Tree nuts',
      'peanuts' => 'Peanuts',
      'milk' => 'Milk',
      'egg' => 'Egg',
      'gluten' => 'Gluten',
      'seafood' => 'Fish & seafood',
      'soy' => 'Soy',
      'sesame' => 'Sesame',
      'pregnant' => 'Pregnant or breastfeeding',
      'diabetes' => 'Diabetes or insulin resistance',
      'kidney' => 'Kidney disease',
      'eating_disorder' => 'An eating disorder, now or in the past',
      'other' => 'Another condition my diet should consider',
      'night_snacking' => 'Snacking at night',
      'sweets' => 'Craving sweets',
      'portions' => 'Big portions',
      'irregular_meals' => 'Skipping or irregular meals',
      'low_water' => 'Not drinking enough water',
      'eating_out' => 'Eating out often',
      'emotional_eating' => 'Eating when stressed or bored',
      _ => key,
    });

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _page = PageController();
  _Step _step = _Step.welcome;
  bool _loading = true;
  bool _saving = false;

  final _name = TextEditingController();
  String? _goal; // lose / maintain / gain / healthy
  String _pace = 'normal';
  Sex _sex = Sex.female;
  DateTime? _birth;
  final _height = TextEditingController();
  final _weight = TextEditingController();
  final _target = TextEditingController();
  Activity _activity = Activity.light;
  final Set<String> _dietPrefs = {};
  final Set<String> _allergies = {};
  final _otherAllergy = TextEditingController();
  final Set<String> _health = {};
  bool _healthNone = false;
  int _meals = 3;
  final Set<String> _challenges = {};
  bool? _hasDietitianCode;
  bool _reminders = true;
  Map<String, dynamic>? _reminderTimes;
  bool _hasWeight = false;
  double? _loadedWeight;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await db.from('profiles').select().eq('id', myId).single();
      final r = await db.from('reminder_settings').select().eq('user_id', myId).maybeSingle();
      final w = await db.from('weight_entries').select('weight_kg').eq('client_id', myId).order('measured_on', ascending: false).limit(1);
      _name.text = p['full_name'] as String? ?? '';
      _sex = switch (p['sex']) { 'male' => Sex.male, 'other' => Sex.other, _ => Sex.female };
      _birth = p['birth_date'] == null ? null : DateTime.parse(p['birth_date'] as String);
      _height.text = asNum(p['height_cm'])?.toString() ?? '';
      _reminderTimes = r;
      _reminders = r?['enabled'] as bool? ?? true;
      if (w.isNotEmpty) {
        _loadedWeight = asNum(w.first['weight_kg'])?.toDouble();
        _weight.text = _loadedWeight.toString();
        _hasWeight = true;
      }
      if (widget.redo) {
        _goal = p['goal'] as String?;
        _pace = p['goal_pace'] as String? ?? 'normal';
        _target.text = asNum(p['target_weight_kg'])?.toString() ?? '';
        _activity = Activity.values.firstWhere((a) => a.name == p['activity_level'], orElse: () => Activity.light);
        _dietPrefs.addAll([for (final x in p['diet_preferences'] as List? ?? const []) x as String]);
        final allergies = [for (final x in p['allergies'] as List? ?? const []) x as String];
        _allergies.addAll(allergies.where(_allergyList.contains));
        _otherAllergy.text = allergies.where((a) => !_allergyList.contains(a)).join(', ');
        _health.addAll([for (final x in p['health_flags'] as List? ?? const []) x as String]..remove('under_18'));
        _healthNone = _health.isEmpty;
        _meals = p['meals_per_day'] as int? ?? 3;
        _challenges.addAll([for (final x in p['challenges'] as List? ?? const []) x as String]);
        _hasDietitianCode = false;
      }
    } catch (_) {
      // Questions still work with empty defaults.
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---------------------------------------------------------------- flow ----
  List<_Step> get _steps => [
        for (final s in _Step.values)
          if (!(s == _Step.target && (_goal == 'maintain' || _goal == 'healthy')))
            if (!(s == _Step.dietitian && widget.redo)) s,
      ];

  int get _index => _steps.indexOf(_step);

  double? _n(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  int? get _age => _birth == null ? null : (DateTime.now().difference(_birth!).inDays / 365.25).floor();

  bool get _canContinue => switch (_step) {
        _Step.welcome => _name.text.trim().isNotEmpty,
        _Step.goal => _goal != null,
        _Step.body => _birth != null && (_age ?? 0) >= 13 && _inRange(_n(_height), 120, 230) && _inRange(_n(_weight), 30, 300),
        _Step.target => _inRange(_n(_target), 30, 300) && _targetMakesSense,
        _Step.health => _healthNone || _health.isNotEmpty,
        _Step.dietitian => _hasDietitianCode != null,
        _ => true,
      };

  bool _inRange(double? v, double lo, double hi) => v != null && v >= lo && v <= hi;

  bool get _targetMakesSense {
    final now = _n(_weight), target = _n(_target);
    if (now == null || target == null) return false;
    return _goal == 'lose' ? target < now : target > now;
  }

  void _go(int delta) {
    FocusScope.of(context).unfocus();
    final next = _index + delta;
    if (next < 0) return;
    if (next >= _steps.length) return;
    setState(() => _step = _steps[next]);
    _page.jumpToPage(next);
  }

  // ------------------------------------------------------------ the plan ----
  /// Health situations where we don't suggest losing or gaining on our own.
  bool get _noDeficit => _health.contains('pregnant') || _health.contains('eating_disorder') || (_age ?? 18) < 18;
  bool get _seeDietitian => _noDeficit || _health.contains('diabetes') || _health.contains('kidney') || _health.contains('other');

  Goal get _calcGoal {
    if (_noDeficit) return Goal.maintain;
    return switch (_goal) {
      'lose' => _pace == 'slow' ? Goal.loseSlow : Goal.lose,
      'gain' => Goal.gain,
      _ => Goal.maintain,
    };
  }

  TargetPlan? get _plan {
    final h = _n(_height), w = _n(_weight), age = _age;
    if (h == null || w == null || age == null) return null;
    return calculateTargets(sex: _sex, age: age, heightCm: h, weightKg: w, activity: _activity, goal: _calcGoal);
  }

  /// Rough weeks to the target weight at the chosen pace (0.25 / 0.5 kg a week; gain ~0.25).
  int? get _weeks {
    if (_noDeficit || _goal == 'maintain' || _goal == 'healthy') return null;
    final now = _n(_weight), target = _n(_target);
    if (now == null || target == null) return null;
    final perWeek = _goal == 'gain' ? 0.25 : (_pace == 'slow' ? 0.25 : 0.5);
    return ((now - target).abs() / perWeek).ceil();
  }

  List<String> get _healthFlags => [..._health, if ((_age ?? 18) < 18) 'under_18'];

  Future<void> _finish({bool skipped = false}) async {
    final router = GoRouter.of(context);
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    try {
      final plan = skipped ? null : _plan;
      final allergies = [
        ..._allergies,
        ..._otherAllergy.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
      ];
      await db.from('profiles').update({
        'onboarded_at': DateTime.now().toUtc().toIso8601String(),
        if (!skipped) ...{
          'full_name': _name.text.trim(),
          'sex': _sex.name,
          'birth_date': isoDate.format(_birth!),
          'height_cm': _n(_height),
          'goal': _goal,
          'goal_pace': _goal == 'lose' ? _pace : null,
          'target_weight_kg': _steps.contains(_Step.target) ? _n(_target) : null,
          'activity_level': _activity.name,
          'diet_preferences': _dietPrefs.toList(),
          'allergies': allergies,
          'health_flags': _healthFlags,
          'challenges': _challenges.toList(),
          'meals_per_day': _meals,
        },
      }).eq('id', myId);
      if (!skipped) {
        final w = _n(_weight)!;
        if (!_hasWeight || w != _loadedWeight) {
          await db.from('weight_entries').insert({'client_id': myId, 'measured_on': today(), 'weight_kg': w});
        }
        // Targets only when no dietitian sets them (the database refuses otherwise).
        final link = await db.from('client_links').select('id').eq('client_id', myId).eq('status', 'active').maybeSingle();
        if (plan != null && link == null) {
          await db.from('nutrition_targets').upsert({
            'client_id': myId,
            'calories': plan.calories,
            'protein_g': plan.proteinG,
            'carbs_g': plan.carbsG,
            'fat_g': plan.fatG,
            'water_ml': plan.waterMl,
          });
        }
        await db.from('reminder_settings').update({'enabled': _reminders}).eq('user_id', myId);
        await Reminders.sync();
      }
      await widget.session.reload();
      if (widget.redo) {
        nav.pop(true);
      } else {
        router.go(_hasDietitianCode == true && !skipped ? '/join' : '/c');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  // ------------------------------------------------------------------ UI ----
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final last = _step == _Step.plan;
    return Scaffold(
      appBar: AppBar(
        leading: _index > 0
            ? IconButton(tooltip: t('Back'), onPressed: () => _go(-1), icon: const Icon(Icons.arrow_back))
            : widget.redo
                ? const CloseButton()
                : null,
        title: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(value: (_index + 1) / _steps.length, minHeight: 8),
        ),
        actions: [
          if (!widget.redo && !last)
            TextButton(onPressed: _saving ? null : () => _finish(skipped: true), child: Text(t('Skip for now'))),
        ],
      ),
      body: SafeArea(
        child: PageView(
          controller: _page,
          physics: const NeverScrollableScrollPhysics(),
          children: [for (final s in _steps) _pageFor(s)],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          // heightFactor 1: only as tall as the button (a plain Align would fill the screen).
          child: Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: FilledButton(
              onPressed: !_canContinue || _saving ? null : () => last ? _finish() : _go(1),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54), backgroundColor: last ? null : scheme.primary),
              child: Text(last ? t('Start my plan') : t('Continue')),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _frame({required String title, String? subtitle, required List<Widget> children}) {
    final text = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
      MaxWidth(
        width: 560,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: text.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 20),
          ...children,
        ]),
      ),
    ]);
  }

  /// A big tappable option card.
  Widget _option({required IconData icon, required String title, String? subtitle, required bool selected, required VoidCallback onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(onTap),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(icon, color: selected ? scheme.primary : scheme.onSurfaceVariant, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  if (subtitle != null) Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (selected) Icon(Icons.check_circle, color: scheme.primary),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _chips(List<String> keys, Set<String> selected, {VoidCallback? onChange}) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final k in keys)
          FilterChip(
            label: Text(_label(k)),
            selected: selected.contains(k),
            onSelected: (on) => setState(() {
              on ? selected.add(k) : selected.remove(k);
              onChange?.call();
            }),
          ),
      ]);

  Widget _pageFor(_Step s) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    void changed(_) => setState(() {});
    switch (s) {
      case _Step.welcome:
        return _frame(
          title: t('Welcome to Nouri'),
          subtitle: t('A few quick questions so we can set up targets and tips that fit you. It takes about a minute, and you can change everything later.'),
          children: [
            Icon(Icons.eco_rounded, size: 72, color: scheme.primary),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: t('What should we call you?')),
              onChanged: changed,
            ),
          ],
        );
      case _Step.goal:
        return _frame(
          title: t('What is your main goal, {0}?', [_name.text.trim().split(' ').first]),
          children: [
            for (final (key, icon, title, sub) in [
              ('lose', Icons.trending_down_rounded, t('Lose weight'), t('Lose fat at a pace you can keep')),
              ('maintain', Icons.balance_rounded, t('Maintain my weight'), t('Stay where you are, eat with more awareness')),
              ('gain', Icons.trending_up_rounded, t('Gain weight'), t('Gain weight or muscle gradually')),
              ('healthy', Icons.favorite_outline_rounded, t('Eat healthier'), t('Better habits, no focus on the scale')),
            ])
              _option(icon: icon, title: title, subtitle: sub, selected: _goal == key, onTap: () => _goal = key),
          ],
        );
      case _Step.body:
        return _frame(
          title: t('About you'),
          subtitle: t('Used to estimate how much energy your body needs.'),
          children: [
            SegmentedButton<Sex>(
              segments: [
                ButtonSegment(value: Sex.female, label: Text(t('Female'))),
                ButtonSegment(value: Sex.male, label: Text(t('Male'))),
                ButtonSegment(value: Sex.other, label: Text(t('Other'))),
              ],
              selected: {_sex},
              onSelectionChanged: (v) => setState(() => _sex = v.first),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: context,
                  initialDate: _birth ?? DateTime(now.year - 30, 1, 1),
                  firstDate: DateTime(now.year - 100),
                  lastDate: DateTime(now.year - 13, now.month, now.day),
                  initialDatePickerMode: DatePickerMode.year,
                  helpText: t('Date of birth'),
                );
                if (d != null) setState(() => _birth = d);
              },
              icon: const Icon(Icons.cake_outlined),
              label: Text(_birth == null ? t('Date of birth') : t('Born {0} ({1} years)', [DateFormat.yMMMMd().format(_birth!), _age])),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _height,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('Height'), suffixText: 'cm'),
                  onChanged: changed,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _weight,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: t('Current weight'), suffixText: 'kg'),
                  onChanged: changed,
                ),
              ),
            ]),
          ],
        );
      case _Step.target:
        final lose = _goal == 'lose';
        return _frame(
          title: lose ? t('What weight would you like to reach?') : t('What weight are you aiming for?'),
          children: [
            TextField(
              controller: _target,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: t('Target weight'),
                suffixText: 'kg',
                helperText: t('Now: {0} kg', [_weight.text]),
                errorText: _target.text.isNotEmpty && _n(_target) != null && !_targetMakesSense
                    ? (lose ? t('Should be below your current weight') : t('Should be above your current weight'))
                    : null,
              ),
              onChanged: changed,
            ),
            if (lose) ...[
              const SizedBox(height: 20),
              Text(t('At what pace?'), style: text.titleMedium),
              const SizedBox(height: 8),
              _option(icon: Icons.directions_walk, title: t('Steady'), subtitle: t('About 0.25 kg a week, easier to keep'), selected: _pace == 'slow', onTap: () => _pace = 'slow'),
              _option(icon: Icons.directions_run, title: t('Faster'), subtitle: t('About 0.5 kg a week'), selected: _pace == 'normal', onTap: () => _pace = 'normal'),
            ],
          ],
        );
      case _Step.activity:
        return _frame(
          title: t('How active are you on a normal day?'),
          children: [
            for (final (a, icon) in [
              (Activity.sedentary, Icons.chair_outlined),
              (Activity.light, Icons.directions_walk),
              (Activity.moderate, Icons.directions_bike),
              (Activity.active, Icons.fitness_center),
              (Activity.athlete, Icons.sports_gymnastics),
            ])
              _option(icon: icon, title: t(a.label), subtitle: t(a.hint), selected: _activity == a, onTap: () => _activity = a),
          ],
        );
      case _Step.eating:
        return _frame(
          title: t('How do you eat?'),
          subtitle: t('Pick any that apply. Leave empty if you eat everything.'),
          children: [
            _chips(_diets, _dietPrefs),
            const SizedBox(height: 24),
            Text(t('Any food allergies or intolerances?'), style: text.titleMedium),
            const SizedBox(height: 10),
            _chips(_allergyList, _allergies),
            const SizedBox(height: 10),
            TextField(controller: _otherAllergy, decoration: InputDecoration(labelText: t('Other (comma separated)'))),
          ],
        );
      case _Step.health:
        return _frame(
          title: t('Does any of this apply to you?'),
          subtitle: t('So we never suggest something unsafe. This stays private, and is shared only with a dietitian you choose to work with.'),
          children: [
            for (final h in _healthList)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _health.contains(h),
                title: Text(_label(h)),
                onChanged: (v) => setState(() {
                  v == true ? _health.add(h) : _health.remove(h);
                  if (v == true) _healthNone = false;
                }),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _healthNone,
              title: Text(t('None of these')),
              onChanged: (v) => setState(() {
                _healthNone = v ?? false;
                if (_healthNone) _health.clear();
              }),
            ),
          ],
        );
      case _Step.habits:
        return _frame(
          title: t('A bit about your habits'),
          children: [
            Text(t('How many meals do you usually eat a day?'), style: text.titleMedium),
            const SizedBox(height: 10),
            SegmentedButton<int>(
              segments: [for (final n in [2, 3, 4, 5]) ButtonSegment(value: n, label: Text(n == 5 ? '5+' : '$n'))],
              selected: {_meals},
              onSelectionChanged: (v) => setState(() => _meals = v.first),
            ),
            const SizedBox(height: 24),
            Text(t('What gets in your way most?'), style: text.titleMedium),
            const SizedBox(height: 4),
            Text(t('We\'ll send tips for these.'), style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            _chips(_challengeList, _challenges),
          ],
        );
      case _Step.dietitian:
        return _frame(
          title: t('Are you working with a dietitian?'),
          subtitle: t('Nouri works on its own, or together with your dietitian. They can follow your log and set your targets.'),
          children: [
            _option(icon: Icons.vpn_key_outlined, title: t('Yes, I have an invite code'), subtitle: t('You\'ll enter it after this'), selected: _hasDietitianCode == true, onTap: () => _hasDietitianCode = true),
            _option(icon: Icons.person_outline, title: t('No, I\'ll use Nouri on my own'), subtitle: t('You can join a dietitian any time'), selected: _hasDietitianCode == false, onTap: () => _hasDietitianCode = false),
          ],
        );
      case _Step.reminders:
        String time(String k) => (_reminderTimes?[k] as String? ?? '').split(':').take(2).join(':');
        return _frame(
          title: t('Want a nudge at meal times?'),
          subtitle: t('People who log right after eating keep it up much longer.'),
          children: [
            _option(icon: Icons.notifications_active_outlined, title: t('Yes, remind me'), subtitle: _reminderTimes == null ? null : t('Breakfast {0} · Lunch {1} · Dinner {2}. Change them in your profile.', [time('breakfast'), time('lunch'), time('dinner')]), selected: _reminders, onTap: () => _reminders = true),
            _option(icon: Icons.notifications_off_outlined, title: t('No reminders'), selected: !_reminders, onTap: () => _reminders = false),
          ],
        );
      case _Step.plan:
        return _planPage();
    }
  }

  Widget _planPage() {
    final c = context.nouri;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final p = _plan;
    final weeks = _weeks;
    Widget stat(String label, String value, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
            child: Column(children: [
              Text(value, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        );
    final tips = tipsFor(challenges: _challenges.toList(), goal: _goal, dietPreferences: _dietPrefs.toList()).take(3).toList();
    return _frame(
      title: t('Your plan is ready, {0}', [_name.text.trim().split(' ').first]),
      children: [
        if (p != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(t('Daily target'), style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
                Text(t('{0} kcal', [p.calories]), style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: c.link)),
                const SizedBox(height: 12),
                Row(children: [
                  stat(t('Protein'), '${p.proteinG} g', c.protein),
                  const SizedBox(width: 8),
                  stat(t('Carbs'), '${p.carbsG} g', c.carbs),
                  const SizedBox(width: 8),
                  stat(t('Fat'), '${p.fatG} g', c.fat),
                  const SizedBox(width: 8),
                  stat(t('Water'), '${(p.waterMl / 1000).toStringAsFixed(1)} L', c.water),
                ]),
                if (weeks != null) ...[
                  const SizedBox(height: 14),
                  Row(children: [
                    Icon(Icons.flag_outlined, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(t('At this pace you could reach {0} kg in about {1} weeks.', [_target.text, weeks]))),
                  ]),
                ],
                if (p.raisedToMinimum)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(t('Raised to 1200 kcal, the usual minimum without medical supervision. For a lower target, please work with a dietitian.'),
                        style: text.bodySmall?.copyWith(color: scheme.error)),
                  ),
              ]),
            ),
          ),
        if (_seeDietitian)
          Card(
            color: scheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: Text(_noDeficit ? t('We set a target to keep your weight steady') : t('A dietitian can tailor this for you')),
              subtitle: Text(_noDeficit
                  ? t('With what you told us, losing or gaining weight should be planned with a dietitian or doctor. Nouri still helps you track meals and water.')
                  : t('Your health situation can change what is right for you. Consider sharing your plan with a dietitian or doctor.')),
            ),
          ),
        if (_allergies.isNotEmpty || _otherAllergy.text.trim().isNotEmpty || _dietPrefs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              t('Saved for your dietitian and future suggestions: {0}', [
                [..._dietPrefs.map(_label), ..._allergies.map(_label), if (_otherAllergy.text.trim().isNotEmpty) _otherAllergy.text.trim()].join(', ')
              ]),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (tips.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(t('Tips for you'), style: text.titleMedium),
          const SizedBox(height: 8),
          for (final tip in tips)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(tip.icon, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(tip.text)),
              ]),
            ),
        ],
        const SizedBox(height: 8),
        Text(t('These are general estimates, not medical advice.'), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }
}
