import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/features.dart';
import '../../core/session.dart';
import '../../core/ui.dart';
import '../../core/i18n.dart';
import '../foods/food.dart';
import '../foods/food_picker.dart';
import '../foods/meal_review.dart';
import '../foods/photo_recognizer.dart';

/// How a meal gets into the log. Every path ends on the same confirmation
/// screen ([reviewMeal]), with values from the foods table.
///   search      -> pick a food           (source 'manual')
///   describe    -> estimate-meal (rules) (source 'text')
///   barcode     -> lookup-barcode (OFF)  (source 'barcode')
///   photo       -> on-device recognition (source 'photo', kPhotoRecognition; free)
/// Returns 'saved', 'manual' (type the values yourself) or null.
Future<String?> addToMeal(BuildContext context, {required String slot, required String day}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Align(alignment: Alignment.centerLeft, child: Text(t('Add to {0}', [mealName(slot)]), style: Theme.of(c).textTheme.titleLarge)),
        ),
        ListTile(
          leading: const Icon(Icons.search),
          title: Text(t('Search foods')),
          subtitle: Text(t('Pick from Nouri\'s food database')),
          onTap: () => Navigator.pop(c, 'search'),
        ),
        ListTile(
          leading: const Icon(Icons.edit_note),
          title: Text(t('Describe your meal')),
          subtitle: Text(t('e.g. 2 boiled eggs, 1 slice of bread')),
          onTap: () => Navigator.pop(c, 'describe'),
        ),
        ListTile(
          leading: const Icon(Icons.qr_code_scanner),
          title: Text(t('Barcode')),
          subtitle: Text(t('Packaged products')),
          onTap: () => Navigator.pop(c, 'barcode'),
        ),
        if (kPhotoRecognition)
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(t('Photo')),
            subtitle: Text(t('Recognised on your phone, free')),
            onTap: () => Navigator.pop(c, 'photo'),
          ),
        ListTile(
          leading: const Icon(Icons.keyboard_outlined),
          title: Text(t('I know the values, enter them myself')),
          onTap: () => Navigator.pop(c, 'manual'),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return null;
  switch (choice) {
    case 'manual':
      return 'manual';
    case 'search':
      final food = await pickFood(context);
      if (food == null || !context.mounted) return null;
      return await reviewMeal(context, items: [LogItem.food(food)], slot: slot, day: day, source: 'manual') ? 'saved' : null;
    case 'barcode':
      final food = await findByBarcode(context);
      if (food == null || !context.mounted) return null;
      return await reviewMeal(context, items: [LogItem.food(food)], slot: slot, day: day, source: 'barcode') ? 'saved' : null;
    case 'describe':
      return describeMeal(context, slot: slot, day: day);
    case 'photo':
      return await scanMeal(context, slot: slot, day: day) ? 'saved' : null;
  }
  return null;
}

/// Photo -> on-device recognition (free, offline) -> pick what was on the
/// plate -> review with values from the foods table.
Future<bool> scanMeal(BuildContext context, {required String slot, required String day}) async {
  if (!kPhotoRecognition) return false;
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined),
          title: Text(t('Take a photo')),
          onTap: () => Navigator.pop(c, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: Text(t('Choose from gallery')),
          onTap: () => Navigator.pop(c, ImageSource.gallery),
        ),
      ]),
    ),
  );
  if (source == null) return false;
  // 1024 px, JPEG 80%: plenty for recognition, small to upload.
  final photo = await ImagePicker().pickImage(source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 80);
  if (photo == null || !context.mounted) return false;
  final bytes = await photo.readAsBytes();
  if (!context.mounted) return false;

  List<PhotoGuess>? guesses;
  List<Food> foods = const [];
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => _AnalyzingDialog(
      run: () async {
        final recognizer = await FoodPhotoRecognizer.instance();
        guesses = await recognizer.recognize(bytes);
        if (guesses!.isNotEmpty) {
          final rows = await db.from('foods').select(Food.rowSelect).inFilter('seed_key', [for (final g in guesses!) g.seedKey]) as List;
          final byKey = {for (final r in rows) (r as Map)['seed_key'] as String: Food.fromRow(Map<String, dynamic>.from(r))};
          foods = [for (final g in guesses!) ?byKey[g.seedKey]];
        }
      },
    ),
  );
  if (guesses == null || !context.mounted) return false;

  final picked = await Navigator.of(context).push<List<Food>>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _PhotoGuessesScreen(photo: bytes, foods: foods),
  ));
  if (picked == null || !context.mounted) return false;

  // Keep the photo with the entry (the dietitian sees it); logging works without it.
  String? path;
  try {
    path = '$myId/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await db.storage.from('meal-photos').uploadBinary(path, bytes);
  } catch (_) {
    path = null;
  }
  if (!context.mounted) return false;
  final aiRaw = {'model': 'mobileclip_s0 (on device)', 'guesses': [for (final g in guesses!) g.toJson()]};
  return reviewMeal(
    context,
    items: [for (final f in picked) LogItem.food(f, aiRaw: aiRaw)],
    slot: slot,
    day: day,
    source: 'photo',
    photo: bytes,
    photoPath: path,
  );
}

/// "We think we see…": the recognised foods as a checklist (the most likely
/// ones ticked), plus a search for anything that was missed.
class _PhotoGuessesScreen extends StatefulWidget {
  const _PhotoGuessesScreen({required this.photo, required this.foods});
  final Uint8List photo;
  final List<Food> foods;

  @override
  State<_PhotoGuessesScreen> createState() => _PhotoGuessesScreenState();
}

class _PhotoGuessesScreenState extends State<_PhotoGuessesScreen> {
  late final List<Food> _options = [...widget.foods];
  // Tick the best guess that can be logged (dishes with no values yet can't be).
  late final Set<String> _picked = {?widget.foods.where((f) => f.hasValues).firstOrNull?.id};

  Future<void> _search() async {
    final f = await pickFood(context);
    if (f == null) return;
    setState(() {
      if (!_options.any((o) => o.id == f.id)) _options.add(f);
      _picked.add(f.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final chosen = _options.where((f) => _picked.contains(f.id)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(t('What is on your plate?'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        MaxWidth(
          width: 640,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.memory(widget.photo, height: 220, fit: BoxFit.cover)),
            const SizedBox(height: 14),
            if (widget.foods.isEmpty)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.no_food_outlined),
                  title: Text(t('We could not recognise food in this photo')),
                  subtitle: Text(t('Search for what you ate instead.')),
                ),
              )
            else ...[
              Text(t('We think we see:'), style: text.titleMedium),
              Text(t('Tick everything on your plate. Recognition runs on your phone and can be wrong, so check it.'),
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
            ],
            for (final f in _options)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _picked.contains(f.id),
                onChanged: (v) => setState(() => v == true ? _picked.add(f.id) : _picked.remove(f.id)),
                title: Text(f.name),
                subtitle: f.hasValues
                    ? Align(alignment: Alignment.centerLeft, child: FoodSourceChip(f))
                    : Text(t('Recognised, but its values aren\'t in the database yet. Pick a similar food or search.'),
                        style: TextStyle(color: scheme.error)),
                enabled: f.hasValues,
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _search, icon: const Icon(Icons.search), label: Text(t('Something else? Search'))),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: chosen.isEmpty ? null : () => Navigator.pop(context, chosen),
            child: Text(t('Continue')),
          ),
        ),
      ),
    );
  }
}
/// "Describe what you ate" -> estimate -> review -> food entries.
/// Returns 'saved', 'manual' (the user wants to type values themselves) or null.
Future<String?> describeMeal(BuildContext context, {required String slot, required String day}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _DescribeMealScreen(slot: slot, day: day),
    ));

class _DescribeMealScreen extends StatefulWidget {
  const _DescribeMealScreen({required this.slot, required this.day});
  final String slot;
  final String day;

  @override
  State<_DescribeMealScreen> createState() => _DescribeMealScreenState();
}

class _DescribeMealScreenState extends State<_DescribeMealScreen> {
  final _text = TextEditingController();
  bool _busy = false;

  static const _phrases = ['1 piece', '1 slice', '1 glass', '1 tea glass', '1 tbsp', '1 portion', '100 g', 'large', 'small'];

  void _insert(String phrase) {
    final s = _text.text;
    final sep = s.isEmpty || s.endsWith(' ') || s.endsWith('\n') ? '' : ' ';
    _text.text = '$s$sep$phrase ';
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    setState(() {});
  }

  Future<void> _calculate() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await db.functions.invoke('estimate-meal', body: {
        'text': text,
        'meal': widget.slot,
        'language': PlatformDispatcher.instance.locale.languageCode,
      });
      if (!mounted) return;
      final r = Map<String, dynamic>.from(res.data as Map);
      final saved = await reviewMeal(
        context,
        items: [for (final i in (r['items'] as List? ?? const [])) LogItem.fromEstimate(Map<String, dynamic>.from(i as Map))],
        slot: widget.slot,
        day: widget.day,
        source: 'text',
        notes: r['notes'] as String?,
      );
      if (saved && mounted) Navigator.pop(context, 'saved');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('Add to {0}', [mealName(widget.slot)]))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        MaxWidth(
          width: 640,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t('What did you eat?'), style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(
              t('Write each food with its amount, using household measures: "2 adet", "1 dilim", "1 su bardağı", "1 yemek kaşığı". We match them to Nouri\'s food database and you can check everything before logging.'),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 4,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: t('e.g. 2 boiled eggs, 1 slice of whole-wheat bread, 5 black olives, 2 tea glasses of tea'),
                hintMaxLines: 3,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in _phrases) ActionChip(label: Text(t(p)), onPressed: () => _insert(t(p))),
            ]),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _busy || _text.text.trim().isEmpty ? null : _calculate,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Icon(Icons.calculate_outlined),
              label: Text(t('Calculate calories')),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.pop(context, 'manual'),
              child: Text(t('I know the values, enter them myself')),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Upload a meal photo and ask the `analyze-meal` function to estimate it (AI, behind kAiEnabled).
/// Returns the storage path (to attach to the entry) and the raw estimate.
Future<({String path, Map<String, dynamic> result})> uploadAndAnalyze(Uint8List bytes, String slot) async {
  final path = '$myId/${DateTime.now().millisecondsSinceEpoch}.jpg';
  await db.storage.from('meal-photos').uploadBinary(path, bytes);
  final res = await db.functions.invoke('analyze-meal', body: {
    'photo_path': path,
    'meal': slot,
    'language': PlatformDispatcher.instance.locale.languageCode,
  });
  return (path: path, result: Map<String, dynamic>.from(res.data as Map));
}

/// Collapse an estimate into one entry: names joined, nutrition summed.
({String name, num calories, num protein, num carbs, num fat})? combineEstimate(Map<String, dynamic> result) {
  final items = [
    for (final i in (result['items'] as List? ?? const [])) LogItem.fromEstimate(Map<String, dynamic>.from(i as Map)),
  ].where((i) => i.ready).toList();
  if (result['is_food'] == false || items.isEmpty) return null;
  final n = items.fold<Nutrition>(Nutrition.zero, (s, i) => s + i.nutrition!);
  num r1(num v) => (v * 10).round() / 10;
  return (
    name: items.map((i) => i.name.text).join(', '),
    calories: n.calories.round(),
    protein: r1(n.protein),
    carbs: r1(n.carbs),
    fat: r1(n.fat),
  );
}

class _AnalyzingDialog extends StatefulWidget {
  const _AnalyzingDialog({required this.run});
  final Future<void> Function() run;

  @override
  State<_AnalyzingDialog> createState() => _AnalyzingDialogState();
}

class _AnalyzingDialogState extends State<_AnalyzingDialog> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.run().then((_) {
      if (mounted) Navigator.pop(context);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return AlertDialog(
        title: Text(t('Could not analyse the photo')),
        content: Text(t('{0}\n\nYou can still add the meal manually.', [errorText(_error!)])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t('OK')))],
      );
    }
    return AlertDialog(
      content: Row(children: [
        const CircularProgressIndicator(),
        const SizedBox(width: 20),
        Expanded(child: Text(t('Analysing your meal…\nThis can take a few seconds.'))),
      ]),
    );
  }
}
