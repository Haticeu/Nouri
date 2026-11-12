import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/nutrition_safety.dart';
import '../../core/reminders.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';
import '../../widgets/target_calculator.dart';
import '../../widgets/targets.dart';
import '../../widgets/water_glasses.dart';
import '../../core/features.dart';
import '../foods/food_picker.dart';
import '../foods/meal_review.dart';
import '../onboarding/personal_tips.dart';
import 'meal_scan.dart';
import 'target_request.dart';
import '../../core/i18n.dart';

const mealSlots = ['breakfast', 'lunch', 'dinner', 'snack'];


class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  DateTime _day = DateTime.now();
  late Future<_TodayData> _future = _load();

  Future<_TodayData> _load() async {
    final day = isoDate.format(_day);
    final results = await Future.wait([
      db.from('food_entries').select().eq('client_id', myId).eq('logged_on', day).order('logged_at', ascending: true),
      db.from('water_entries').select('id, amount_ml').eq('client_id', myId).eq('logged_on', day).order('created_at', ascending: true),
      db.from('nutrition_targets').select().eq('client_id', myId).maybeSingle(),
      db.from('client_links').select('dietitian_id').eq('client_id', myId).eq('status', 'active').maybeSingle(),
      db.from('comments').select().eq('client_id', myId).or('log_date.eq.$day,food_entry_id.not.is.null'),
      // RLS returns only posts from the client's current dietitian.
      db.from('broadcasts').select().gte('created_at', DateTime.now().subtract(const Duration(days: 7)).toUtc().toIso8601String())
          .order('created_at', ascending: false).limit(1),
      db.from('profiles').select('full_name').eq('id', myId).maybeSingle(),
    ]);
    unawaited(Reminders.sync()); // skip today's reminder for meals already logged
    return _TodayData(
      entries: List<Map<String, dynamic>>.from(results[0] as List),
      water: List<Map<String, dynamic>>.from(results[1] as List),
      targets: results[2] as Map<String, dynamic>?,
      dietitianId: (results[3] as Map<String, dynamic>?)?['dietitian_id'] as String?,
      comments: List<Map<String, dynamic>>.from(results[4] as List),
      latestPost: (results[5] as List).isEmpty ? null : Map<String, dynamic>.from((results[5] as List).first as Map),
      fullName: (results[6] as Map<String, dynamic>?)?['full_name'] as String?,
    );
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Loader<_TodayData>(
      future: _future,
      builder: (context, d) {
        final day = isoDate.format(_day);
        final dayComments = d.comments.where((c) => c['log_date'] == day).toList();
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            MaxWidth(
              width: 640,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _header(d),
                const SizedBox(height: 14),
                _summary(d),
                const SizedBox(height: 12),
                WaterTracker(
                  consumedMl: d.waterMl,
                  targetMl: (d.targets?['water_ml'] as int?) ?? 2000,
                  onAdd: _addWater,
                  onUndo: d.water.isEmpty ? null : () => _removeWater(d),
                  onSetTotal: (ml) => _setWaterTotal(d, ml),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  // Photo scanning is an AI feature; without it the main action is adding food.
                  onPressed: () => _addEntry(_slotForNow()),
                  icon: const Icon(Icons.add_rounded, size: 22),
                  label: Text(t('Add food')),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(58),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 12),
                if (d.latestPost != null) BroadcastCard(post: d.latestPost!, compact: true),
                const PersonalTipCard(),
                for (final c in dayComments) _CommentBubble(c),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Text(t('Meals'), style: Theme.of(context).textTheme.titleLarge),
                ),
                for (final slot in mealSlots) _mealCard(d, slot),
              ]),
            ),
          ]),
        );
      },
    );
  }

  String _greeting(String? fullName) {
    final h = DateTime.now().hour;
    final part = h < 12 ? t('Good morning') : (h < 18 ? t('Good afternoon') : t('Good evening'));
    final first = (fullName ?? '').trim().split(RegExp(r'\s+')).first;
    return first.isEmpty ? part : '$part, $first';
  }

  Widget _header(_TodayData d) {
    final text = Theme.of(context).textTheme;
    final isToday = isoDate.format(_day) == today();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_greeting(d.fullName), style: text.headlineSmall),
      const SizedBox(height: 2),
      Row(children: [
        IconButton(
          tooltip: t('Previous day'),
          visualDensity: VisualDensity.compact,
          onPressed: () {
            _day = _day.subtract(const Duration(days: 1));
            _reload();
          },
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Text(isToday ? t('Today · {0}', [DateFormat('EEEE d MMMM').format(_day)]) : DateFormat('EEEE d MMMM').format(_day),
            style: text.titleSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
        IconButton(
          tooltip: t('Next day'),
          visualDensity: VisualDensity.compact,
          onPressed: isToday
              ? null
              : () {
                  _day = _day.add(const Duration(days: 1));
                  _reload();
                },
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ]),
    ]);
  }

  /// Calorie ring + macro bars, with the target controls underneath.
  Widget _summary(_TodayData d) {
    final c = context.nouri;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final kcal = d.total('calories');
    final target = d.targets?['calories'] as int?;
    final left = target == null ? null : target - kcal;
    final over = left != null && left < 0;
    final warnings = d.targets == null ? const <TargetWarning>[] : warningsFor(d.targets!);

    Widget bar(String label, num value, int? goal, Color color) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(label, style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(goal == null ? '${value.round()} g' : '${value.round()} / $goal g',
                style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              minHeight: 9,
              value: goal == null || goal == 0 ? 0 : (value / goal).clamp(0, 1).toDouble(),
              color: color,
              backgroundColor: color.withValues(alpha: 0.16),
            ),
          ),
        ]);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            SizedBox(
              width: 128,
              height: 128,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: target == null || target == 0 ? 0 : (kcal / target).clamp(0, 1).toDouble(),
                    strokeWidth: 13,
                    strokeCap: StrokeCap.round,
                    color: over ? c.carbs : scheme.primary,
                    backgroundColor: c.track,
                  ),
                ),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${(left?.abs() ?? kcal).round()}', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  Text(left == null ? t('kcal eaten') : (over ? t('kcal over') : t('kcal left')),
                      style: text.labelMedium?.copyWith(color: over ? c.carbs : scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(children: [
                bar(t('Protein'), d.total('protein_g'), d.targets?['protein_g'] as int?, c.protein),
                const SizedBox(height: 10),
                bar(t('Carbs'), d.total('carbs_g'), d.targets?['carbs_g'] as int?, c.carbs),
                const SizedBox(height: 10),
                bar(t('Fat'), d.total('fat_g'), d.targets?['fat_g'] as int?, c.fat),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Text(
                target == null
                    ? t('No calorie target yet')
                    : d.dietitianId != null
                        ? t('{0} of {1} kcal · set by your dietitian', [kcal.round(), target])
                        : t('{0} of {1} kcal', [kcal.round(), target]),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ),
            if (d.dietitianId == null) ...[
              TextButton(
                onPressed: () async {
                  if (await showTargetCalculator(context)) _reload();
                },
                child: Text(target == null ? t('Calculate my targets') : t('Recalculate')),
              ),
              if (target != null)
                IconButton(
                  tooltip: t('Edit targets'),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: () async {
                    if (await editTargets(context, myId, d.targets, asDietitian: false)) _reload();
                  },
                ),
            ] else
                TextButton(
                    onPressed: () => requestTargetChange(context, d.dietitianId!, d.targets),
                    child: Text(t('Request change'))),
          ]),
          WarningList(warnings: warnings),
        ]),
      ),
    );
  }

  static const _slotStyle = {
    'breakfast': Icons.wb_sunny_rounded,
    'lunch': Icons.lunch_dining_rounded,
    'dinner': Icons.nightlight_round,
    'snack': Icons.cookie_rounded,
  };

  Color _slotColor(String slot) {
    final c = context.nouri;
    return switch (slot) {
      'breakfast' => c.carbs,
      'lunch' => c.protein,
      'dinner' => c.fat,
      _ => c.water,
    };
  }

  Widget _mealCard(_TodayData d, String slot) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final entries = d.entries.where((e) => e['meal'] == slot).toList();
    final kcal = entries.fold<num>(0, (s, e) => s + (asNum(e['calories']) ?? 0));
    final color = _slotColor(slot);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
              child: Icon(_slotStyle[slot], color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(mealName(slot), style: text.titleMedium),
                Text(entries.isEmpty ? t('Not logged yet') : '${kcal.round()} kcal',
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
              ]),
            ),
            if (kPhotoRecognition)
              IconButton(tooltip: t('Scan with camera'), icon: const Icon(Icons.photo_camera_outlined), onPressed: () => _scan(slot))
            else
              IconButton(tooltip: t('Barcode'), icon: const Icon(Icons.qr_code_scanner), onPressed: () => _barcode(slot)),
            IconButton.filledTonal(tooltip: t('Add food'), icon: const Icon(Icons.add_rounded), onPressed: () => _addEntry(slot)),
          ]),
          for (final e in entries) ...[
            const Divider(height: 18),
            Row(children: [
              const SizedBox(width: 4),
              if (e['photo_path'] != null) ...[
                Icon(Icons.photo_outlined, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e['name'] as String, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    [
                      '${asNum(e['calories'])?.round() ?? 0} kcal',
                      if (e['protein_g'] != null) t('P {0}g', [asNum(e['protein_g'])!.round()]),
                      if (e['carbs_g'] != null) t('C {0}g', [asNum(e['carbs_g'])!.round()]),
                      if (e['fat_g'] != null) t('F {0}g', [asNum(e['fat_g'])!.round()]),
                    ].join(' · '),
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ]),
              ),
              IconButton(
                tooltip: t('Delete'),
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  await db.from('food_entries').delete().eq('id', e['id']);
                  _reload();
                },
              ),
            ]),
            for (final c in d.comments.where((c) => c['food_entry_id'] == e['id'])) _CommentBubble(c),
          ],
        ]),
      ),
    );
  }

  Future<void> _addWater(int ml) async {
    try {
      await db.from('water_entries').insert({'client_id': myId, 'logged_on': isoDate.format(_day), 'amount_ml': ml});
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Replace the day's water log with one entry holding the total.
  Future<void> _setWaterTotal(_TodayData d, int ml) async {
    try {
      final day = isoDate.format(_day);
      await db.from('water_entries').delete().eq('client_id', myId).eq('logged_on', day);
      if (ml > 0) await db.from('water_entries').insert({'client_id': myId, 'logged_on': day, 'amount_ml': ml});
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Undo the most recent drink of the day.
  Future<void> _removeWater(_TodayData d) async {
    if (d.water.isEmpty) return;
    try {
      await db.from('water_entries').delete().eq('id', d.water.last['id']);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Meal slot that fits the current time of day.
  String _slotForNow() {
    final h = DateTime.now().hour;
    if (h < 11) return 'breakfast';
    if (h < 15) return 'lunch';
    if (h < 18) return 'snack';
    return 'dinner';
  }

  Future<void> _scan(String slot) async {
    if (await scanMeal(context, slot: slot, day: isoDate.format(_day))) _reload();
  }

  Future<void> _barcode(String slot) async {
    final food = await findByBarcode(context);
    if (food == null || !mounted) return;
    final saved = await reviewMeal(context, items: [LogItem.food(food)], slot: slot, day: isoDate.format(_day), source: 'barcode');
    if (saved) _reload();
  }

  /// Search, describe or scan the meal, or type the values for those who know them.
  Future<void> _addEntry(String slot) async {
    final result = await addToMeal(context, slot: slot, day: isoDate.format(_day));
    if (result == 'saved') {
      _reload();
    } else if (result == 'manual' && mounted) {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _FoodEntryDialog(slot: slot, day: isoDate.format(_day)),
      );
      if (saved == true) _reload();
    }
  }
}

class _TodayData {
  _TodayData({
    required this.entries,
    required this.water,
    required this.targets,
    required this.dietitianId,
    required this.comments,
    required this.latestPost,
    required this.fullName,
  });
  final Map<String, dynamic>? latestPost;
  final String? fullName;
  final List<Map<String, dynamic>> entries;
  final List<Map<String, dynamic>> water;
  int get waterMl => water.fold<int>(0, (s, r) => s + (r['amount_ml'] as int));
  num total(String key) => entries.fold<num>(0, (s, e) => s + (asNum(e[key]) ?? 0));
  final Map<String, dynamic>? targets;
  final String? dietitianId;
  final List<Map<String, dynamic>> comments;
}

class _CommentBubble extends StatelessWidget {
  const _CommentBubble(this.c);
  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: Text(c['body'] as String),
          subtitle: Text(t('Comment from your dietitian')),
        ),
      );
}

class _FoodEntryDialog extends StatefulWidget {
  const _FoodEntryDialog({required this.slot, required this.day});
  final String slot;
  final String day;

  @override
  State<_FoodEntryDialog> createState() => _FoodEntryDialogState();
}

class _FoodEntryDialogState extends State<_FoodEntryDialog> {
  final _name = TextEditingController();
  final _kcal = TextEditingController();
  final _p = TextEditingController();
  final _c = TextEditingController();
  final _f = TextEditingController();
  int? _satiety;
  int? _energy;
  Uint8List? _photoBytes;
  String? _photoPath; // already uploaded while analysing
  bool _analyzing = false;
  String? _photoNote; // what happened with the photo estimate
  bool _photoNoteIsError = false;
  bool _saving = false;

  /// Pick a photo, upload it, and fill the fields from Claude's estimate.
  Future<void> _pickPhoto(ImageSource source) async {
    final x = await ImagePicker().pickImage(source: source, maxWidth: 1568, maxHeight: 1568, imageQuality: 85);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() {
      _photoBytes = bytes;
      _photoPath = null;
      _analyzing = true;
      _photoNote = null;
    });
    try {
      final r = await uploadAndAnalyze(bytes, widget.slot);
      _photoPath = r.path;
      final est = combineEstimate(r.result);
      if (est == null) {
        _photoNote = t('No food recognised in this photo. Fill in the details yourself.');
        _photoNoteIsError = true;
      } else {
        _name.text = est.name;
        _kcal.text = '${est.calories}';
        _p.text = '${est.protein}';
        _c.text = '${est.carbs}';
        _f.text = '${est.fat}';
        _photoNoteIsError = false;
        _photoNote = t('Filled in from your photo. These are estimates, so check them and edit if needed.');
      }
    } catch (e) {
      _photoNote = t('Could not analyse the photo ({0}). You can still fill in the details.', [errorText(e)]);
      _photoNoteIsError = true;
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Widget _photoSection() {
    final scheme = Theme.of(context).colorScheme;
    if (_photoBytes == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('Add a photo and we\'ll fill in the rest'), style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _pickPhoto(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(t('Camera')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _pickPhoto(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(t('Gallery')),
              ),
            ),
          ]),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_photoBytes!, height: 160, width: double.infinity, fit: BoxFit.cover),
        ),
        if (_analyzing)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                CircularProgressIndicator(),
                SizedBox(height: 10),
                Text(t('Reading your photo…'), style: TextStyle(color: Colors.white)),
              ]),
            ),
          ),
        if (!_analyzing)
          Positioned(
            right: 6,
            top: 6,
            child: IconButton.filledTonal(
              tooltip: t('Use another photo'),
              onPressed: () => _pickPhoto(ImageSource.gallery),
              icon: const Icon(Icons.refresh),
            ),
          ),
      ]),
      if (_photoNote != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_photoNoteIsError ? Icons.info_outline : Icons.auto_awesome,
                size: 18, color: _photoNoteIsError ? scheme.error : scheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(_photoNote!, style: Theme.of(context).textTheme.bodySmall)),
          ]),
        ),
    ]);
  }

  Widget _rating(String label, int? value, ValueChanged<int> onPick) => Row(children: [
        SizedBox(width: 70, child: Text(label)),
        for (var i = 1; i <= 5; i++)
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => onPick(i)),
            icon: Icon(value != null && i <= value ? Icons.circle : Icons.circle_outlined, size: 18),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t('Add to {0}', [mealName(widget.slot)])),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (kAiEnabled) ...[
              _photoSection(),
              const SizedBox(height: 8),
            ],
            TextField(controller: _name, decoration: InputDecoration(labelText: t('Food'))),
            TextField(controller: _kcal, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Calories'))),
            Row(children: [
              Expanded(child: TextField(controller: _p, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Protein g')))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _c, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Carbs g')))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _f, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('Fat g')))),
            ]),
            const SizedBox(height: 8),
            _rating(t('Satiety'), _satiety, (v) => _satiety = v),
            _rating(t('Energy'), _energy, (v) => _energy = v),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
        FilledButton(onPressed: _saving || _analyzing ? null : _save, child: Text(t('Add'))),
      ],
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      // Usually uploaded already during analysis; upload now if that failed.
      var photoPath = _photoPath;
      if (photoPath == null && _photoBytes != null) {
        photoPath = '$myId/${DateTime.now().millisecondsSinceEpoch}.jpg';
        await db.storage.from('meal-photos').uploadBinary(photoPath, _photoBytes!);
      }
      await db.from('food_entries').insert({
        'client_id': myId,
        'logged_on': widget.day,
        'meal': widget.slot,
        'name': _name.text.trim(),
        'calories': num.tryParse(_kcal.text) ?? 0,
        'protein_g': num.tryParse(_p.text),
        'carbs_g': num.tryParse(_c.text),
        'fat_g': num.tryParse(_f.text),
        'satiety_rating': _satiety,
        'energy_rating': _energy,
        'photo_path': photoPath,
        'source': 'manual',
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
      setState(() => _saving = false);
    }
  }
}
