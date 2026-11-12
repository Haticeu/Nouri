import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n.dart';
import '../../core/session.dart';
import '../../core/ui.dart';
import '../foods/food.dart';

/// Dietitians review the food database: fill in dishes that have no values
/// yet, correct values and household measures, and mark foods as verified.
/// Only verified dietitians (and admins) can change anything; the database
/// enforces it (update_food / verify_food / create_food).
class FoodsScreen extends StatefulWidget {
  const FoodsScreen({super.key, required this.session});
  final AppSession session;

  @override
  State<FoodsScreen> createState() => _FoodsScreenState();
}

enum _Filter { todo, unverified, verified, all }

class _FoodsScreenState extends State<FoodsScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  _Filter _filter = _Filter.todo;
  int _limit = 60;
  late Future<_FoodsData> _future = _load();

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<_FoodsData> _load() async {
    final statsF = db.rpc('food_stats');
    final statusF = db.rpc('my_workspace_status');
    final q = _query.text.trim();
    List<Food> foods;
    if (q.length >= 2) {
      foods = (await searchFoods(q, limit: 50)).where(_matches).toList();
    } else {
      var query = db.from('foods').select('*, portion_units(unit, size, grams_per_unit, source, sort)');
      query = switch (_filter) {
        _Filter.todo => query.eq('source', 'todo'),
        _Filter.unverified => query.neq('source', 'todo').eq('verified', false),
        _Filter.verified => query.eq('verified', true),
        _Filter.all => query,
      };
      final rows = await query.order('name_tr', ascending: true).limit(_limit) as List;
      foods = [for (final r in rows) Food(_withPortions(Map<String, dynamic>.from(r as Map)))];
    }
    final stats = Map<String, dynamic>.from(((await statsF) as List).first as Map);
    final status = (await statusF) as List;
    final approved = status.isNotEmpty && (status.first as Map)['verification_status'] == 'approved';
    return _FoodsData(foods: foods, stats: stats, canEdit: approved || widget.session.isAdmin);
  }

  bool _matches(Food f) => switch (_filter) {
        _Filter.todo => f.source == 'todo',
        _Filter.unverified => f.source != 'todo' && !f.verified,
        _Filter.verified => f.verified,
        _Filter.all => true,
      };

  static Map<String, dynamic> _withPortions(Map<String, dynamic> row) {
    final units = [for (final u in (row.remove('portion_units') as List? ?? const [])) Map<String, dynamic>.from(u as Map)]
      ..sort((a, b) => (asNum(a['sort']) ?? 0).compareTo(asNum(b['sort']) ?? 0));
    return {
      ...row,
      'portions': [for (final u in units) {'unit': u['unit'], 'size': u['size'], 'grams': u['grams_per_unit'], 'source': u['source']}],
    };
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _open(Food? food, bool canEdit) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => FoodEditor(food: food, canEdit: canEdit),
    ));
    if (changed == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Loader<_FoodsData>(
      future: _future,
      builder: (context, d) => Scaffold(
        floatingActionButton: d.canEdit
            ? FloatingActionButton.extended(onPressed: () => _open(null, true), icon: const Icon(Icons.add), label: Text(t('New food')))
            : null,
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
          MaxWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!d.canEdit)
                Card(
                  color: scheme.secondaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: Text(t('Only verified dietitians can edit foods')),
                    subtitle: Text(t('You can browse the database. Once your credential is approved, you can fill in missing values and verify foods.')),
                  ),
                ),
              Text(
                t('Values come from USDA FoodData Central (basic foods and close equivalents of dishes) and Open Food Facts (barcodes). Turkish dishes with no source have no values until a dietitian adds them. Verified foods show a badge to clients.'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _query,
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: t('Search foods')),
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), _reload);
                },
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (f, label, n) in [
                  (_Filter.todo, t('Needs values'), d.stats['todo']),
                  (_Filter.unverified, t('Not verified'), d.stats['unverified']),
                  (_Filter.verified, t('Verified'), d.stats['verified']),
                  (_Filter.all, t('All'), d.stats['total']),
                ])
                  ChoiceChip(
                    label: Text('$label · $n'),
                    selected: _filter == f,
                    onSelected: (_) {
                      _filter = f;
                      _limit = 60;
                      _reload();
                    },
                  ),
              ]),
              const SizedBox(height: 8),
              if (d.foods.isEmpty) EmptyHint(t('No foods here.')),
              for (final f in d.foods)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    onTap: () => _open(f, d.canEdit),
                    title: Text(f.brand == null ? f.nameTr : '${f.nameTr} · ${f.brand}'),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(f.nameEn),
                      const SizedBox(height: 4),
                      Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        FoodSourceChip(f),
                        if (f.hasValues)
                          Text(t('{0} kcal / 100 g', [f.per100('kcal')!.round()]), style: Theme.of(context).textTheme.labelMedium),
                        if (f.sourceNote?.startsWith('Approximation') ?? false)
                          Text(t('Approximation'), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.tertiary)),
                      ]),
                    ]),
                    trailing: const Icon(Icons.chevron_right),
                  ),
                ),
              if (_query.text.trim().length < 2 && d.foods.length >= _limit)
                TextButton(
                  onPressed: () {
                    _limit += 60;
                    _reload();
                  },
                  child: Text(t('Show more')),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _FoodsData {
  _FoodsData({required this.foods, required this.stats, required this.canEdit});
  final List<Food> foods;
  final Map<String, dynamic> stats;
  final bool canEdit;
}

class _PortionRow {
  _PortionRow(this.unit, this.size, double? grams, this.source)
      : grams = TextEditingController(text: grams == null ? '' : _num(grams));
  String unit;
  String? size;
  final TextEditingController grams;
  final String? source;
}

String _num(num v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

/// View and (for verified dietitians) edit one food. Returns true if saved.
class FoodEditor extends StatefulWidget {
  const FoodEditor({super.key, required this.food, required this.canEdit});
  final Food? food; // null = new food
  final bool canEdit;

  @override
  State<FoodEditor> createState() => _FoodEditorState();
}

class _FoodEditorState extends State<FoodEditor> {
  late final Map<String, dynamic> _j = widget.food?.json ?? const {};
  late final _nameTr = TextEditingController(text: _j['name_tr'] as String? ?? '');
  late final _nameEn = TextEditingController(text: _j['name_en'] as String? ?? '');
  late final _aliases = TextEditingController(text: ((_j['aliases'] as List?) ?? const []).join(', '));
  // A todo row's note is our placeholder ("needs values"); the dietitian writes their own source.
  late final _note = TextEditingController(text: _j['source'] == 'todo' ? '' : _j['source_note'] as String? ?? '');
  late final Map<String, TextEditingController> _values = {
    for (final k in ['kcal', 'protein', 'carbs', 'fat', 'fiber'])
      k: TextEditingController(text: asNum(_j['${k}_per_100g']) == null ? '' : _num(asNum(_j['${k}_per_100g'])!)),
  };
  late final List<_PortionRow> _portions = [
    for (final p in widget.food?.portions ?? const <Portion>[]) _PortionRow(p.unit, p.size, p.grams, p.source),
  ];
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.food == null;

  double? _val(String k) => double.tryParse(_values[k]!.text.trim().replaceAll(',', '.'));

  Map<String, dynamic>? _collect() {
    final required = ['kcal', 'protein', 'carbs', 'fat'];
    final filled = required.where((k) => _values[k]!.text.trim().isNotEmpty).length;
    if (_nameTr.text.trim().isEmpty) return _fail(t('Enter the Turkish name.'));
    if (filled != 0 && filled != required.length) return _fail(t('Enter calories, protein, carbs and fat together (per 100 g).'));
    if ((_isNew || widget.food!.hasValues) && filled == 0) return _fail(t('Enter calories, protein, carbs and fat (per 100 g).'));
    for (final k in [...required, 'fiber']) {
      final text = _values[k]!.text.trim();
      if (text.isEmpty) continue;
      final v = _val(k);
      if (v == null || v < 0 || v > (k == 'kcal' ? 900 : 100)) return _fail(t('Check the value for {0}.', [_label(k)]));
    }
    final portions = <Map<String, dynamic>>[];
    for (final p in _portions) {
      final g = double.tryParse(p.grams.text.trim().replaceAll(',', '.'));
      if (g == null || g <= 0 || g > 5000) return _fail(t('Check the grams for {0}.', [unitLabel(p.unit, p.size)]));
      if (portions.any((x) => x['unit'] == p.unit && x['size'] == p.size)) {
        return _fail(t('{0} is listed twice.', [unitLabel(p.unit, p.size)]));
      }
      portions.add({'unit': p.unit, 'size': p.size, 'grams': g});
    }
    _error = null;
    return {
      'name_tr': _nameTr.text.trim(),
      'name_en': _nameEn.text.trim(),
      'aliases': _aliases.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      'source_note': _note.text.trim(),
      if (filled > 0) ...{
        for (final k in required) '${k}_per_100g': _val(k),
        'fiber_per_100g': _values['fiber']!.text.trim().isEmpty ? null : _val('fiber'),
      },
      'portions': portions,
    };
  }

  Map<String, dynamic>? _fail(String message) {
    setState(() => _error = message);
    return null;
  }

  Future<void> _save({required bool verify}) async {
    final data = _collect();
    if (data == null) return;
    if (verify && data['kcal_per_100g'] == null) {
      setState(() => _error = t('Add the nutrition values before verifying this food.'));
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isNew) {
        await db.rpc('create_food', params: {'p_data': data, 'p_verify': verify});
      } else {
        await db.rpc('update_food', params: {'p_food': widget.food!.id, 'p_data': data, 'p_verify': verify});
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  Future<void> _unverify() async {
    setState(() => _saving = true);
    try {
      await db.rpc('verify_food', params: {'p_food': widget.food!.id, 'p_verified': false});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  String _label(String k) => switch (k) {
        'kcal' => t('Calories (kcal)'),
        'protein' => t('Protein g'),
        'carbs' => t('Carbs g'),
        'fat' => t('Fat g'),
        _ => t('Fiber g'),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final food = widget.food;
    final edit = widget.canEdit;
    final numFmt = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? t('New food') : food!.nameTr)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        MaxWidth(
          width: 720,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (food != null)
              SectionCard(
                title: t('Source'),
                action: FoodSourceChip(food),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (food.sourceRef != null) SelectableText(food.sourceRef!),
                  if (food.source == 'todo')
                    Text(t('No source has values for this dish yet. Enter them from TürKomp or a recipe calculation, and name the source in the note.'),
                        style: TextStyle(color: scheme.error)),
                  if (food.verified)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(t('Verified {0}', [dateTimeFmt.format(parseTs(food.json['verified_at'])!)]), style: text.bodySmall),
                    ),
                  if (food.source == 'open_food_facts')
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(t('Product data © Open Food Facts contributors, under the Open Database License (ODbL).'), style: text.bodySmall),
                    ),
                ]),
              ),
            SectionCard(
              title: t('Names'),
              child: Column(children: [
                TextField(controller: _nameTr, enabled: edit, decoration: InputDecoration(labelText: t('Turkish name'))),
                TextField(controller: _nameEn, enabled: edit, decoration: InputDecoration(labelText: t('English name'))),
                TextField(
                  controller: _aliases,
                  enabled: edit,
                  decoration: InputDecoration(labelText: t('Other names (comma separated)'), helperText: t('Used by search and meal descriptions')),
                ),
              ]),
            ),
            SectionCard(
              title: t('Per 100 g'),
              child: Column(children: [
                Wrap(spacing: 12, runSpacing: 4, children: [
                  for (final k in ['kcal', 'protein', 'carbs', 'fat', 'fiber'])
                    SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _values[k],
                        enabled: edit,
                        inputFormatters: numFmt,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: _label(k)),
                      ),
                    ),
                ]),
                TextField(
                  controller: _note,
                  enabled: edit,
                  maxLines: 2,
                  decoration: InputDecoration(labelText: t('Note (where the values come from)')),
                ),
              ]),
            ),
            SectionCard(
              title: t('Household measures'),
              action: edit
                  ? TextButton.icon(
                      onPressed: () => setState(() => _portions.add(_PortionRow('kase', null, null, null))),
                      icon: const Icon(Icons.add),
                      label: Text(t('Add')),
                    )
                  : null,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(t('How many grams one measure holds. Measures from USDA are converted to Turkish ones (su bardağı = 200 ml, çay bardağı = 100 ml).'),
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                if (_portions.isEmpty) EmptyHint(t('Only grams for now.')),
                for (final p in _portions)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      Expanded(
                        flex: 3,
                        child: DropdownButtonFormField<String>(
                          initialValue: p.unit,
                          isExpanded: true,
                          decoration: InputDecoration(labelText: t('Measure'), isDense: true),
                          items: [for (final u in allUnits) DropdownMenuItem(value: u, child: Text(unitLabel(u)))],
                          onChanged: edit ? (u) => setState(() => p.unit = u ?? p.unit) : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String?>(
                          initialValue: p.size,
                          isExpanded: true,
                          decoration: InputDecoration(labelText: t('Size'), isDense: true),
                          items: [
                            DropdownMenuItem(value: null, child: Text(t('Any'))),
                            for (final s in allSizes) DropdownMenuItem(value: s, child: Text(appLang == 'tr' ? s : t(cap(s == 'küçük' ? 'small' : s == 'orta' ? 'medium' : 'large')))),
                          ],
                          onChanged: edit ? (s) => setState(() => p.size = s) : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 80,
                        child: TextField(
                          controller: p.grams,
                          enabled: edit,
                          inputFormatters: numFmt,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: 'g', isDense: true),
                        ),
                      ),
                      if (edit)
                        IconButton(tooltip: t('Remove'), onPressed: () => setState(() => _portions.remove(p)), icon: const Icon(Icons.close))
                      else
                        const SizedBox(width: 8),
                    ]),
                  ),
              ]),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: TextStyle(color: scheme.error))),
            if (edit) ...[
              FilledButton.icon(
                onPressed: _saving ? null : () => _save(verify: true),
                icon: const Icon(Icons.verified),
                label: Text(t('Save and verify')),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _saving ? null : () => _save(verify: false),
                child: Text(t('Save without verifying')),
              ),
              if (food?.verified ?? false)
                TextButton(onPressed: _saving ? null : _unverify, child: Text(t('Remove verification'))),
              const SizedBox(height: 4),
              Text(t('Changing the values makes you the source of this food. Saving without verifying removes an existing verification.'),
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ]),
    );
  }
}
