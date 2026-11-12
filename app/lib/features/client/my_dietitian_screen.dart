import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';
import '../../widgets/plan_view.dart';
import '../../widgets/targets.dart';
import 'find_dietitian_screen.dart';
import 'target_request.dart';
import '../../core/i18n.dart';

class MyDietitianScreen extends StatefulWidget {
  const MyDietitianScreen({super.key});

  @override
  State<MyDietitianScreen> createState() => _MyDietitianScreenState();
}

class _MyDietitianScreenState extends State<MyDietitianScreen> {
  late Future<Map<String, dynamic>?> _future = _load();

  Future<Map<String, dynamic>?> _load() async {
    final link = await db
        .from('client_links')
        .select('dietitian_id, started_at')
        .eq('client_id', myId)
        .eq('status', 'active')
        .maybeSingle();
    if (link == null) return null;
    final dId = link['dietitian_id'] as String;
    final r = await Future.wait<dynamic>([
      db.from('profiles').select('full_name, avatar_url').eq('id', dId).single(),
      db.from('dietitian_profiles').select().eq('user_id', dId).single(),
      db.from('nutrition_targets').select().eq('client_id', myId).maybeSingle(),
      db.from('meal_plans').select('*, meal_plan_items(*)').eq('client_id', myId).eq('dietitian_id', dId).eq('is_active', true).order('created_at', ascending: false).limit(1),
      db.from('recommendations').select().eq('client_id', myId).eq('dietitian_id', dId).order('created_at', ascending: false),
      db.from('appointments').select().eq('client_id', myId).eq('status', 'scheduled').gte('starts_at', DateTime.now().toUtc().toIso8601String()).order('starts_at', ascending: true),
      db.from('audit_log').select().eq('client_id', myId).order('created_at', ascending: false).limit(20),
      db.from('target_change_requests').select().eq('client_id', myId).order('created_at', ascending: false).limit(5),
      db.from('messages').select().eq('client_id', myId).eq('dietitian_id', dId).order('created_at', ascending: false).limit(3),
      db.from('broadcasts').select().eq('dietitian_id', dId).order('created_at', ascending: false).limit(10),
      db.rpc('my_rateable_dietitians').then((r) => List<Map<String, dynamic>>.from(r as List)),
    ]);
    final rating = (r[10] as List).where((x) => x['dietitian_id'] == dId).firstOrNull;
    return {
      'dietitian_id': dId,
      'since': link['started_at'],
      'profile': r[0],
      'dprofile': r[1],
      'targets': r[2],
      'plan': (r[3] as List).isEmpty ? null : (r[3] as List).first,
      'recommendations': r[4],
      'appointments': r[5],
      'history': r[6],
      'requests': r[7],
      'messages': r[8],
      'posts': r[9],
      'rating': rating, // null until 14 days together
    };
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Loader<Map<String, dynamic>?>(
      future: _future,
      builder: (context, d) {
        if (d == null) return _NoDietitian(onJoined: _reload);
        final p = d['profile'] as Map<String, dynamic>;
        final dp = d['dprofile'] as Map<String, dynamic>;
        final dId = d['dietitian_id'] as String;
        final specialties = List<String>.from(dp['specialties'] as List? ?? const []);
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            MaxWidth(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        UserAvatar(
                          url: (dp['photo_url'] ?? p['avatar_url']) as String?,
                          name: p['full_name'] as String?,
                          radius: 28,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(p['full_name'] as String? ?? t('Your dietitian'), style: Theme.of(context).textTheme.titleLarge),
                            if (dp['title'] != null) Text(dp['title'] as String),
                          ]),
                        ),
                        VerifiedBadge(status: dp['verification_status'] as String?),
                      ]),
                      if (specialties.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, children: [for (final s in specialties) Chip(label: Text(s))]),
                      ],
                      if (dp['bio'] != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(dp['bio'] as String)),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton.icon(
                          onPressed: () => context.push('/chat/$dId/$myId').then((_) => _reload()),
                          icon: const Icon(Icons.chat_outlined),
                          label: Text(t('Message')),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => requestTargetChange(context, dId, d['targets'] as Map<String, dynamic>?).then((_) => _reload()),
                          icon: const Icon(Icons.tune),
                          label: Text(t('Request target change')),
                        ),
                        if (d['rating'] != null)
                          OutlinedButton.icon(
                            onPressed: () {
                              final rt = d['rating'] as Map;
                              rateDietitian(context, dId, p['full_name'] as String?,
                                      stars: rt['my_stars'] as int?, comment: rt['my_comment'] as String?)
                                  .then((_) => _reload());
                            },
                            icon: const Icon(Icons.star_outline_rounded),
                            label: Text((d['rating'] as Map)['my_stars'] == null ? t('Rate') : t('Your rating: {0}★', [(d['rating'] as Map)['my_stars']])),
                          ),
                      ]),
                    ]),
                  ),
                ),
                _latestMessages(d['messages'] as List, dId),
                if ((d['posts'] as List).isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Row(children: [
                      const Icon(Icons.campaign_outlined, size: 20),
                      const SizedBox(width: 8),
                      Text(t('From {0}', [p['full_name'] ?? 'your dietitian']), style: Theme.of(context).textTheme.titleMedium),
                    ]),
                  ),
                  for (final post in (d['posts'] as List).take(3))
                    BroadcastCard(post: Map<String, dynamic>.from(post as Map), compact: true, author: p['full_name'] as String?),
                ],
                SectionCard(title: t('Targets'), child: TargetsView(targets: d['targets'] as Map<String, dynamic>?)),
                _requests(d['requests'] as List),
                SectionCard(
                  title: d['plan'] == null ? t('Meal plan') : t('Meal plan: {0}', [(d['plan'] as Map)['name']]),
                  child: d['plan'] == null
                      ? EmptyHint(t('No plan assigned yet.'))
                      : PlanView(plan: d['plan'] as Map<String, dynamic>),
                ),
                SectionCard(
                  title: t('Upcoming appointments'),
                  child: Column(children: [
                    if ((d['appointments'] as List).isEmpty) EmptyHint(t('None scheduled.')),
                    for (final a in d['appointments'] as List)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.event),
                        title: Text(dateTimeFmt.format(parseTs(a['starts_at'])!)),
                        subtitle: Text([a['location'], a['agenda']].whereType<String>().join(' · ')),
                      ),
                  ]),
                ),
                SectionCard(
                  title: t('Recommendations just for you'),
                  child: Column(children: [
                    if ((d['recommendations'] as List).isEmpty) EmptyHint(t('Nothing yet.')),
                    for (final r in d['recommendations'] as List)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(r['title'] as String? ?? r['body'] as String),
                        subtitle: r['title'] != null ? Text(r['body'] as String) : null,
                      ),
                  ]),
                ),
                SectionCard(
                  title: t('Change history'),
                  child: Column(children: [
                    if ((d['history'] as List).isEmpty) EmptyHint(t('No changes yet.')),
                    for (final h in d['history'] as List)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.history, size: 20),
                        title: Text(tServer(h['summary'] as String)),
                        subtitle: Text(dateTimeFmt.format(parseTs(h['created_at'])!)),
                      ),
                  ]),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                  onPressed: _leave,
                  icon: const Icon(Icons.logout),
                  label: Text(t('Leave this dietitian')),
                ),
                const SizedBox(height: 24),
              ]),
            ),
          ]),
        );
      },
    );
  }

  Widget _latestMessages(List messages, String dId) => SectionCard(
        title: t('Latest messages'),
        action: TextButton(onPressed: () => context.push('/chat/$dId/$myId').then((_) => _reload()), child: Text(t('Open chat'))),
        child: Column(children: [
          if (messages.isEmpty) EmptyHint(t('No messages yet.')),
          for (final m in messages)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(m['sender_id'] == myId ? Icons.north_east : Icons.south_west, size: 18),
              title: Text(m['body'] as String? ?? t('📷 Photo'), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(dateTimeFmt.format(parseTs(m['created_at'])!)),
            ),
        ]),
      );

  Widget _requests(List requests) {
    if (requests.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: t('My target requests'),
      child: Column(children: [
        for (final r in requests)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(r['message'] as String),
            subtitle: Text([
              t(cap(r['status'] as String)),
              if (r['response'] != null) t('Reply: {0}', [r['response']]),
            ].join(' · ')),
          ),
      ]),
    );
  }

  Future<void> _leave() async {
    final ok = await confirm(
      context,
      t('Leave your dietitian?'),
      t('Your dietitian will immediately lose access to your food log, weight, measurements, water, photos and messages, and won\'t see anything you log afterwards.\n\nThey keep their own private notes and copies of the meal plans they wrote for you. You keep everything they shared with you.'),
      ok: t('Leave'),
    );
    if (!ok) return;
    try {
      await db.rpc('leave_dietitian');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

/// No dietitian yet: find one in the list (or use an invite code), see the
/// pending request, and rate dietitians the client worked with before.
class _NoDietitian extends StatefulWidget {
  const _NoDietitian({required this.onJoined});
  final VoidCallback onJoined;

  @override
  State<_NoDietitian> createState() => _NoDietitianState();
}

class _NoDietitianState extends State<_NoDietitian> {
  late Future<(Map<String, dynamic>?, List<Map<String, dynamic>>)> _future = _load();

  Future<(Map<String, dynamic>?, List<Map<String, dynamic>>)> _load() async {
    final dietitians = await listDietitians();
    final pending = dietitians.where((d) => d['my_request'] == 'pending').firstOrNull;
    final rateable = List<Map<String, dynamic>>.from(await db.rpc('my_rateable_dietitians') as List);
    return (pending, rateable.where((r) => r['my_stars'] == null).toList());
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _go(String path) async {
    await context.push(path);
    _reload();
    widget.onJoined();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Loader<(Map<String, dynamic>?, List<Map<String, dynamic>>)>(
      future: _future,
      builder: (context, data) {
        final (pending, toRate) = data;
        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            widget.onJoined();
          },
          child: ListView(padding: const EdgeInsets.all(24), children: [
            MaxWidth(
              width: 560,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.support_agent, size: 64),
                const SizedBox(height: 16),
                Text(t('Work with a dietitian'), style: text.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  t('Browse verified dietitians, read reviews and send a request. It\'s free. You\'ll see exactly what they can access before you send it.'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (pending != null) ...[
                  Text(t('Your request'), style: text.titleMedium),
                  const SizedBox(height: 4),
                  DietitianCard(d: pending, onTap: () => _go('/dietitians/${pending['dietitian_id']}')),
                  Text(t('You\'ll get a notification when the dietitian answers.'), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                ],
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => _go('/dietitians'),
                  icon: const Icon(Icons.search),
                  label: Text(t('Find a dietitian')),
                ),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () => _go('/join'), child: Text(t('I have an invite code'))),
                for (final r in toRate) ...[
                  const SizedBox(height: 20),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.star_outline_rounded),
                      title: Text(t('How was working with {0}?', [r['full_name']])),
                      subtitle: Text(t('Your rating helps others choose.')),
                      trailing: FilledButton.tonal(
                        onPressed: () async {
                          if (await rateDietitian(context, r['dietitian_id'] as String, r['full_name'] as String?)) _reload();
                        },
                        child: Text(t('Rate')),
                      ),
                    ),
                  ),
                ],
              ]),
            ),
          ]),
        );
      },
    );
  }
}
