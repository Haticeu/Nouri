import 'package:flutter/material.dart';

import '../onboarding/onboarding_screen.dart' show onboardingLabel;
import 'package:go_router/go_router.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/plan_view.dart';
import '../../widgets/targets.dart';
import '../../widgets/weight_chart.dart';
import '../../core/i18n.dart';

/// Everything about one active client, for their dietitian.
class ClientDetailScreen extends StatefulWidget {
  const ClientDetailScreen({super.key, required this.clientId});
  final String clientId;

  @override
  State<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends State<ClientDetailScreen> {
  String? _name;
  Map<String, dynamic>? _lastLink; // null while loading
  bool get _active => _lastLink?['status'] == 'active';

  @override
  void initState() {
    super.initState();
    _loadLink();
  }

  Future<void> _loadLink() async {
    final links = await db.from('client_links').select('status, client_display_name, started_at, ended_at')
        .eq('dietitian_id', myId).eq('client_id', widget.clientId).order('started_at', ascending: false).limit(1);
    final link = links.isEmpty ? <String, dynamic>{'status': 'none'} : links.first;
    // Profiles are readable only while the client is active.
    final p = link['status'] == 'active'
        ? await db.from('profiles').select('full_name').eq('id', widget.clientId).maybeSingle()
        : null;
    if (mounted) {
      setState(() {
        _lastLink = link;
        _name = p?['full_name'] as String? ?? link['client_display_name'] as String? ?? t('Client');
      });
    }
  }

  Future<void> _remove() async {
    final ok = await confirm(
      context,
      t('Remove {0}?', [_name]),
      t('You will immediately lose access to their logs and messages. You keep your private notes and the plans you wrote.'),
      ok: t('Remove'),
    );
    if (!ok) return;
    try {
      await db.rpc('remove_client', params: {'p_client': widget.clientId});
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.clientId;
    if (_lastLink == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    if (!_active) return _InactiveClientView(clientId: id, name: _name, link: _lastLink!);
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_name ?? ''),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilledButton.tonalIcon(
                onPressed: () => context.push('/chat/$myId/$id'),
                icon: const Icon(Icons.chat_outlined),
                label: Text(t('Message')),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (_) => _remove(),
              itemBuilder: (_) => [PopupMenuItem(value: 'remove', child: Text(t('Remove client')))],
            ),
          ],
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: t('Food log')),
            Tab(text: t('Progress')),
            Tab(text: t('Targets & requests')),
            Tab(text: t('Meal plan')),
            Tab(text: t('Notes')),
            Tab(text: t('Appointments')),
          ]),
        ),
        body: TabBarView(children: [
          _LogTab(clientId: id),
          _ProgressTab(clientId: id),
          _TargetsTab(clientId: id),
          _PlanTab(clientId: id),
          _NotesTab(clientId: id),
          _AppointmentsTab(clientId: id),
        ]),
      ),
    );
  }
}

/// A client who left (or was removed). Only what the dietitian authored for
/// themselves is kept: private notes and the plans they wrote. No client data.
class _InactiveClientView extends StatefulWidget {
  const _InactiveClientView({required this.clientId, required this.name, required this.link});
  final String clientId;
  final String? name;
  final Map<String, dynamic> link;

  @override
  State<_InactiveClientView> createState() => _InactiveClientViewState();
}

class _InactiveClientViewState extends State<_InactiveClientView> {
  late Future<List<List<Map<String, dynamic>>>> _future = _load();

  Future<List<List<Map<String, dynamic>>>> _load() => Future.wait([
        db.from('private_notes').select().eq('client_id', widget.clientId).order('created_at', ascending: false),
        db.from('meal_plans').select('*, meal_plan_items(*)').eq('client_id', widget.clientId).eq('dietitian_id', myId)
            .order('created_at', ascending: false),
      ]);

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final l = widget.link;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.name ?? t('Former client'))),
      body: Loader<List<List<Map<String, dynamic>>>>(
        future: _future,
        builder: (context, d) => ListView(padding: const EdgeInsets.all(16), children: [
          MaxWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                color: scheme.surfaceContainerHighest,
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: const Icon(Icons.person_off_outlined),
                  title: Text(t('Inactive client')),
                  subtitle: Text([
                    if (l['started_at'] != null && l['ended_at'] != null)
                      '${dateFmt.format(parseTs(l['started_at'])!)} – ${dateFmt.format(parseTs(l['ended_at'])!)}',
                    t('You no longer have access to their logs or messages. Your private notes and the plans you wrote are kept here.'),
                  ].join('\n')),
                ),
              ),
              SectionCard(
                title: t('Private notes'),
                child: Column(children: [
                  if (d[0].isEmpty) EmptyHint(t('None.')),
                  for (final n in d[0]) PrivateNoteTile(note: n, onChanged: _reload),
                ]),
              ),
              SectionCard(
                title: t('Plans you wrote'),
                child: Column(children: [
                  if (d[1].isEmpty) EmptyHint(t('None.')),
                  for (final p in d[1])
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(p['name'] as String),
                      subtitle: Text(dateFmt.format(parseTs(p['created_at'])!)),
                      children: [PlanView(plan: p)],
                    ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Small helper: a tab that loads data and can reload itself.
abstract class _LoadingTab<W extends StatefulWidget, T> extends State<W> with AutomaticKeepAliveClientMixin {
  late Future<T> future = load();
  Future<T> load();
  Widget view(BuildContext context, T data);
  void reload() => setState(() => future = load());

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Loader<T>(
      future: future,
      builder: (context, data) => RefreshIndicator(
        onRefresh: () async => reload(),
        child: ListView(padding: const EdgeInsets.all(16), children: [MaxWidth(child: view(context, data))]),
      ),
    );
  }

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
      reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

// ---------------------------------------------------------------- Food log
class _LogTab extends StatefulWidget {
  const _LogTab({required this.clientId});
  final String clientId;
  @override
  State<_LogTab> createState() => _LogTabState();
}

class _LogTabState extends _LoadingTab<_LogTab, (List<Map<String, dynamic>>, List<Map<String, dynamic>>)> {
  final _photoUrls = <String, Future<String>>{};

  @override
  Future<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)> load() async {
    final since = isoDate.format(DateTime.now().subtract(const Duration(days: 14)));
    final entries = await db.from('food_entries').select().eq('client_id', widget.clientId).gte('logged_on', since)
        .order('logged_on', ascending: false).order('logged_at', ascending: true);
    final comments = await db.from('comments').select().eq('client_id', widget.clientId).eq('dietitian_id', myId);
    return (entries, comments);
  }

  Future<void> _comment({String? entryId, String? day}) async {
    final body = await promptText(context, entryId != null ? t('Comment on this meal') : t('Comment on this day'), maxLines: 3, ok: t('Post'));
    if (body == null || body.isEmpty) return;
    await run(() => db.from('comments').insert({
          'dietitian_id': myId,
          'client_id': widget.clientId,
          'food_entry_id': entryId,
          'log_date': entryId == null ? day : null,
          'body': body,
        }));
  }

  @override
  Widget view(BuildContext context, (List<Map<String, dynamic>>, List<Map<String, dynamic>>) data) {
    final (entries, comments) = data;
    if (entries.isEmpty) return EmptyHint(t('Nothing logged in the last 14 days.'));
    final days = entries.map((e) => e['logged_on'] as String).toSet().toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final day in days)
        Builder(builder: (context) {
          final dayEntries = entries.where((e) => e['logged_on'] == day).toList();
          final kcal = dayEntries.fold<num>(0, (s, e) => s + (asNum(e['calories']) ?? 0));
          return SectionCard(
            title: t('{0} · {1} kcal', [dateFmt.format(DateTime.parse(day)), kcal.round()]),
            action: TextButton.icon(onPressed: () => _comment(day: day), icon: const Icon(Icons.add_comment_outlined), label: Text(t('Comment day'))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final c in comments.where((c) => c['log_date'] == day)) _commentChip(c),
              for (final e in dayEntries) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: e['photo_path'] == null ? null : _thumb(e['photo_path'] as String),
                  title: Text('${mealName(e['meal'] as String)}: ${e['name']}'),
                  subtitle: Text([
                    '${asNum(e['calories'])?.round() ?? 0} kcal',
                    if (e['protein_g'] != null) t('P {0}g', [asNum(e['protein_g'])]),
                    if (e['carbs_g'] != null) t('C {0}g', [asNum(e['carbs_g'])]),
                    if (e['fat_g'] != null) t('F {0}g', [asNum(e['fat_g'])]),
                    if (e['satiety_rating'] != null) t('satiety {0}/5', [e['satiety_rating']]),
                    if (e['energy_rating'] != null) t('energy {0}/5', [e['energy_rating']]),
                  ].join(' · ')),
                  trailing: IconButton(
                    tooltip: t('Comment on meal'),
                    icon: const Icon(Icons.add_comment_outlined),
                    onPressed: () => _comment(entryId: e['id'] as String),
                  ),
                ),
                for (final c in comments.where((c) => c['food_entry_id'] == e['id'])) _commentChip(c),
              ],
            ]),
          );
        }),
    ]);
  }

  Widget _commentChip(Map<String, dynamic> c) => Padding(
        padding: const EdgeInsets.only(left: 16, bottom: 6),
        child: Row(children: [
          const Icon(Icons.subdirectory_arrow_right, size: 16),
          const SizedBox(width: 4),
          Expanded(child: Text(c['body'] as String, style: const TextStyle(fontStyle: FontStyle.italic))),
        ]),
      );

  Widget _thumb(String path) => FutureBuilder<String>(
        future: _photoUrls.putIfAbsent(path, () => db.storage.from('meal-photos').createSignedUrl(path, 3600)),
        builder: (context, s) => SizedBox(
          width: 48,
          height: 48,
          child: s.hasData
              ? GestureDetector(
                  onTap: () => showDialog<void>(context: context, builder: (_) => Dialog(child: Image.network(s.data!))),
                  child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(s.data!, fit: BoxFit.cover)),
                )
              : const Icon(Icons.photo_outlined),
        ),
      );
}

// ---------------------------------------------------------------- Progress
class _ProgressTab extends StatefulWidget {
  const _ProgressTab({required this.clientId});
  final String clientId;
  @override
  State<_ProgressTab> createState() => _ProgressTabState();
}

class _ProgressTabState extends _LoadingTab<_ProgressTab, List<List<Map<String, dynamic>>>> {
  @override
  Future<List<List<Map<String, dynamic>>>> load() => Future.wait([
        db.from('weight_entries').select().eq('client_id', widget.clientId).order('measured_on', ascending: false),
        db.from('profiles').select('birth_date, height_cm, sex').eq('id', widget.clientId),
        db.from('body_measurements').select().eq('client_id', widget.clientId).order('measured_on', ascending: false).limit(10),
        db.from('water_entries').select().eq('client_id', widget.clientId)
            .gte('logged_on', isoDate.format(DateTime.now().subtract(const Duration(days: 7)))),
      ]);

  @override
  Widget view(BuildContext context, List<List<Map<String, dynamic>>> d) {
    final water = <String, int>{};
    for (final w in d[2]) {
      water.update(w['logged_on'] as String, (v) => v + (w['amount_ml'] as int), ifAbsent: () => w['amount_ml'] as int);
    }
    final waterDays = water.keys.toList()..sort((a, b) => b.compareTo(a));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _profileCard(d[3].isEmpty ? const {} : d[3].first, d[0].isEmpty ? null : asNum(d[0].first['weight_kg'])),
      SectionCard(title: t('Weight'), child: WeightChart(entries: d[0])),
      SectionCard(
        title: t('Measurements'),
        child: Column(children: [
          if (d[1].isEmpty) EmptyHint(t('No measurements logged.')),
          for (final m in d[1])
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(dateFmt.format(DateTime.parse(m['measured_on'] as String))),
              subtitle: Text([
                if (m['waist_cm'] != null) t('waist {0} cm', [asNum(m['waist_cm'])]),
                if (m['hip_cm'] != null) t('hip {0} cm', [asNum(m['hip_cm'])]),
                if (m['chest_cm'] != null) t('chest {0} cm', [asNum(m['chest_cm'])]),
                if (m['body_fat_pct'] != null) t('body fat {0}%', [asNum(m['body_fat_pct'])]),
              ].join(' · ')),
            ),
        ]),
      ),
      SectionCard(
        title: t('Water (last 7 days)'),
        child: Column(children: [
          if (waterDays.isEmpty) EmptyHint(t('No water logged.')),
          for (final day in waterDays)
            ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(dateFmt.format(DateTime.parse(day))), trailing: Text(t('{0} ml', [water[day]]))),
        ]),
      ),
    ]);
  }
}

/// Age, height, sex and BMI (from the latest weigh-in), as entered by the client.
Widget _profileCard(Map<String, dynamic> p, num? latestKg) {
  final birth = p['birth_date'] == null ? null : DateTime.parse(p['birth_date'] as String);
  final age = birth == null ? null : (DateTime.now().difference(birth).inDays / 365.25).floor();
  final h = asNum(p['height_cm']);
  final bmi = (h != null && h > 0 && latestKg != null) ? latestKg / ((h / 100) * (h / 100)) : null;
  String v(Object? x) => x == null ? '–' : '$x';
  return SectionCard(
    title: t('Client details'),
    child: Wrap(spacing: 32, runSpacing: 12, children: [
      for (final (label, value) in [
        (t('Age'), v(age)),
        (t('Height'), h == null ? '–' : '$h cm'),
        (t('Sex'), p['sex'] == null ? '–' : t(cap(p['sex'] as String))),
        (t('BMI'), bmi == null ? '–' : bmi.toStringAsFixed(1)),
      ])
        Builder(builder: (context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              Text(value, style: Theme.of(context).textTheme.titleMedium),
            ])),
      // First-run answers (goal, eating style, allergies, health notes, habits).
      ...[
        for (final (label, values) in [
          (t('Goal'), [if (p['goal'] != null) onboardingLabel('goal_${p['goal']}'), if (p['target_weight_kg'] != null) t('target {0} kg', [asNum(p['target_weight_kg'])])]),
          (t('Activity'), [if (p['activity_level'] != null) onboardingLabel('activity_${p['activity_level']}')]),
          (t('Eating style'), [for (final x in p['diet_preferences'] as List? ?? const []) onboardingLabel(x as String)]),
          (t('Allergies'), [for (final x in p['allergies'] as List? ?? const []) onboardingLabel(x as String)]),
          (t('Health notes'), [for (final x in p['health_flags'] as List? ?? const []) onboardingLabel(x as String)]),
          (t('Challenges'), [for (final x in p['challenges'] as List? ?? const []) onboardingLabel(x as String)]),
        ])
          if (values.isNotEmpty)
            Builder(builder: (context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: Theme.of(context).textTheme.labelSmall),
                  Text(values.join(', '),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: label == t('Allergies') || label == t('Health notes') ? Theme.of(context).colorScheme.error : null)),
                ])),
      ],
    ]),
  );
}


// ---------------------------------------------------------------- Targets & requests
class _TargetsTab extends StatefulWidget {
  const _TargetsTab({required this.clientId});
  final String clientId;
  @override
  State<_TargetsTab> createState() => _TargetsTabState();
}

class _TargetsTabState extends _LoadingTab<_TargetsTab, (Map<String, dynamic>?, List<Map<String, dynamic>>)> {
  @override
  Future<(Map<String, dynamic>?, List<Map<String, dynamic>>)> load() async => (
        await db.from('nutrition_targets').select().eq('client_id', widget.clientId).maybeSingle(),
        await db.from('target_change_requests').select().eq('client_id', widget.clientId).order('created_at', ascending: false),
      );

  Future<void> _answer(Map<String, dynamic> r, String status) async {
    final response = await promptText(context, status == 'resolved' ? t('Reply to your client') : t('Why are you declining?'),
        maxLines: 3, ok: status == 'resolved' ? t('Mark handled') : t('Decline'));
    if (response == null) return;
    await run(() => db.from('target_change_requests').update({'status': status, 'response': response.isEmpty ? null : response}).eq('id', r['id']));
  }

  @override
  Widget view(BuildContext context, (Map<String, dynamic>?, List<Map<String, dynamic>>) d) {
    final (targets, requests) = d;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        title: t('Targets'),
        action: FilledButton.tonal(
          onPressed: () async {
            if (await editTargets(context, widget.clientId, targets, asDietitian: true)) reload();
          },
          child: Text(t('Edit')),
        ),
        child: TargetsView(targets: targets),
      ),
      SectionCard(
        title: t('Change requests from client'),
        child: Column(children: [
          if (requests.isEmpty) EmptyHint(t('No requests.')),
          for (final r in requests)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r['message'] as String),
              subtitle: Text([
                dateTimeFmt.format(parseTs(r['created_at'])!),
                if (r['requested_calories'] != null) t('asks {0} kcal', [r['requested_calories']]),
                if (r['requested_protein_g'] != null) t('asks {0} g protein', [r['requested_protein_g']]),
                if (r['status'] != 'open') '${t(cap(r['status'] as String))}${r['response'] != null ? ': ${r['response']}' : ''}',
              ].join(' · ')),
              trailing: r['status'] != 'open'
                  ? null
                  : Wrap(spacing: 4, children: [
                      TextButton(onPressed: () => _answer(r, 'declined'), child: Text(t('Decline'))),
                      FilledButton(onPressed: () => _answer(r, 'resolved'), child: Text(t('Handled'))),
                    ]),
            ),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- Meal plan
class _PlanTab extends StatefulWidget {
  const _PlanTab({required this.clientId});
  final String clientId;
  @override
  State<_PlanTab> createState() => _PlanTabState();
}

class _PlanTabState extends _LoadingTab<_PlanTab, (List<Map<String, dynamic>>, List<Map<String, dynamic>>)> {
  @override
  Future<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)> load() async => (
        await db.from('meal_plans').select('*, meal_plan_items(*)').eq('client_id', widget.clientId).eq('dietitian_id', myId)
            .order('created_at', ascending: false),
        await db.from('meal_plans').select('id, name').eq('dietitian_id', myId).isFilter('client_id', null).order('name', ascending: true),
      );

  Future<void> _assign(List<Map<String, dynamic>> templates) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(t('Assign a template')),
        children: [
          if (templates.isEmpty) Padding(padding: EdgeInsets.all(16), child: Text(t('Create a template first in "Plan templates".'))),
          for (final t in templates)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, t['id'] as String), child: Text(t['name'] as String)),
        ],
      ),
    );
    if (picked == null) return;
    await run(() => db.rpc('assign_meal_plan', params: {'p_template': picked, 'p_client': widget.clientId}));
  }

  @override
  Widget view(BuildContext context, (List<Map<String, dynamic>>, List<Map<String, dynamic>>) d) {
    final (plans, templates) = d;
    final active = plans.where((p) => p['is_active'] == true).toList();
    final past = plans.where((p) => p['is_active'] != true).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        title: active.isEmpty ? t('Current plan') : t('Current plan: {0}', [active.first['name']]),
        action: FilledButton.tonal(onPressed: () => _assign(templates), child: Text(active.isEmpty ? t('Assign') : t('Replace'))),
        child: active.isEmpty
            ? EmptyHint(t('No plan assigned.'))
            : PlanView(
                plan: active.first,
                onDeleteItem: (i) => run(() => db.from('meal_plan_items').delete().eq('id', i['id'])),
              ),
      ),
      if (past.isNotEmpty)
        SectionCard(
          title: t('Previous plans'),
          child: Column(children: [
            for (final p in past) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(p['name'] as String), subtitle: Text(dateFmt.format(parseTs(p['created_at'])!))),
          ]),
        ),
    ]);
  }
}

// ---------------------------------------------------------------- Notes
class _NotesTab extends StatefulWidget {
  const _NotesTab({required this.clientId});
  final String clientId;
  @override
  State<_NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends _LoadingTab<_NotesTab, (List<Map<String, dynamic>>, List<Map<String, dynamic>>)> {
  @override
  Future<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)> load() async => (
        await db.from('recommendations').select().eq('client_id', widget.clientId).eq('dietitian_id', myId).order('created_at', ascending: false),
        await db.from('private_notes').select().eq('client_id', widget.clientId).order('created_at', ascending: false),
      );

  @override
  Widget view(BuildContext context, (List<Map<String, dynamic>>, List<Map<String, dynamic>>) d) {
    final (recs, notes) = d;
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        title: t('Recommendations (visible to client)'),
        action: IconButton(
          icon: const Icon(Icons.add),
          onPressed: () async {
            final body = await promptText(context, t('New recommendation'), maxLines: 4);
            if (body != null && body.isNotEmpty) {
              await run(() => db.from('recommendations').insert({'dietitian_id': myId, 'client_id': widget.clientId, 'body': body}));
            }
          },
        ),
        child: Column(children: [
          if (recs.isEmpty) EmptyHint(t('None yet.')),
          for (final r in recs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r['body'] as String),
              subtitle: Text(dateTimeFmt.format(parseTs(r['created_at'])!)),
              trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => run(() => db.from('recommendations').delete().eq('id', r['id']))),
            ),
        ]),
      ),
      Card(
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.lock_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(t('Private notes — only you can see these'), style: Theme.of(context).textTheme.titleMedium)),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final body = await promptText(context, t('New private note'), maxLines: 4);
                  if (body != null && body.isNotEmpty) {
                    await run(() => db.from('private_notes').insert({'dietitian_id': myId, 'client_id': widget.clientId, 'body': body}));
                  }
                },
              ),
            ]),
            Text(t('You keep these if the client leaves.')),
            if (notes.isEmpty) EmptyHint(t('No private notes.')),
            for (final n in notes) PrivateNoteTile(note: n, onChanged: reload),
          ]),
        ),
      ),
    ]);
  }
}

class PrivateNoteTile extends StatelessWidget {
  const PrivateNoteTile({super.key, required this.note, required this.onChanged});
  final Map<String, dynamic> note;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(note['body'] as String),
        subtitle: Text(dateTimeFmt.format(parseTs(note['updated_at'])!)),
        trailing: Wrap(children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final body = await promptText(context, t('Edit note'), initial: note['body'] as String, maxLines: 4);
              if (body == null || body.isEmpty) return;
              try {
                await db.from('private_notes').update({'body': body, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', note['id']);
                onChanged();
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (!await confirm(context, t('Delete note?'), t('This cannot be undone.'), ok: t('Delete'))) return;
              await db.from('private_notes').delete().eq('id', note['id']);
              onChanged();
            },
          ),
        ]),
      );
}

// ---------------------------------------------------------------- Appointments
class _AppointmentsTab extends StatefulWidget {
  const _AppointmentsTab({required this.clientId});
  final String clientId;
  @override
  State<_AppointmentsTab> createState() => _AppointmentsTabState();
}

class _AppointmentsTabState extends _LoadingTab<_AppointmentsTab, List<Map<String, dynamic>>> {
  @override
  Future<List<Map<String, dynamic>>> load() =>
      db.from('appointments').select().eq('client_id', widget.clientId).eq('dietitian_id', myId).order('starts_at', ascending: false);

  Future<void> _schedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now.add(const Duration(days: 7)));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 10, minute: 0));
    if (time == null || !mounted) return;
    final location = await promptText(context, t('Location or video link (optional)'), ok: t('Next'));
    if (location == null || !mounted) return;
    final agenda = await promptText(context, t('Agenda (optional)'), maxLines: 3, ok: t('Schedule'));
    if (agenda == null) return;
    final startsAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    await run(() => db.from('appointments').insert({
          'dietitian_id': myId,
          'client_id': widget.clientId,
          'starts_at': startsAt.toUtc().toIso8601String(),
          'location': location.isEmpty ? null : location,
          'agenda': agenda.isEmpty ? null : agenda,
        }));
  }

  @override
  Widget view(BuildContext context, List<Map<String, dynamic>> appts) {
    return SectionCard(
      title: t('Appointments'),
      action: FilledButton.tonalIcon(onPressed: _schedule, icon: const Icon(Icons.event), label: Text(t('Schedule'))),
      child: Column(children: [
        if (appts.isEmpty) EmptyHint(t('None scheduled.')),
        for (final a in appts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(dateTimeFmt.format(parseTs(a['starts_at'])!)),
            subtitle: Text([t(cap(a['status'] as String)), a['location'], a['agenda']].whereType<String>().join(' · ')),
            trailing: a['status'] == 'scheduled'
                ? TextButton(
                    onPressed: () => run(() => db.from('appointments').update({'status': 'cancelled'}).eq('id', a['id'])),
                    child: Text(t('Cancel')))
                : null,
          ),
      ]),
    );
  }
}
