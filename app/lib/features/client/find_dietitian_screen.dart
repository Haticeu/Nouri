import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';

/// Verified dietitians the client can ask to work with. Free: no prices.
Future<List<Map<String, dynamic>>> listDietitians([String query = '']) async =>
    List<Map<String, dynamic>>.from(await db.rpc('list_dietitians', params: {'p_query': query}) as List);

class FindDietitianScreen extends StatefulWidget {
  const FindDietitianScreen({super.key});

  @override
  State<FindDietitianScreen> createState() => _FindDietitianScreenState();
}

class _FindDietitianScreenState extends State<FindDietitianScreen> {
  String _query = '';
  late Future<List<Map<String, dynamic>>> _future = listDietitians();

  void _search(String q) {
    _query = q;
    setState(() => _future = listDietitians(q));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Find a dietitian'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        MaxWidth(
          width: 700,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t('Name, city or specialty (e.g. diabetes)'),
              ),
              onSubmitted: _search,
              onChanged: (v) {
                if (v.isEmpty && _query.isNotEmpty) _search('');
              },
            ),
            const SizedBox(height: 8),
            Text(
              t('Only dietitians whose diploma Nouri has checked are listed.'),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Loader<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, rows) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (rows.isEmpty) EmptyHint(_query.isEmpty ? t('No dietitians listed yet.') : t('No dietitians match your search.')),
                for (final d in rows)
                  DietitianCard(
                    d: d,
                    onTap: () => context.push('/dietitians/${d['dietitian_id']}').then((_) => _search(_query)),
                  ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class DietitianCard extends StatelessWidget {
  const DietitianCard({super.key, required this.d, this.onTap});
  final Map<String, dynamic> d;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final specialties = List<String>.from(d['specialties'] as List? ?? const []);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            UserAvatar(url: d['photo_url'] as String?, name: d['full_name'] as String?, radius: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(d['full_name'] as String? ?? t('Dietitian'), style: text.titleMedium)),
                  const SizedBox(width: 6),
                  Icon(Icons.verified, size: 18, color: Theme.of(context).colorScheme.primary),
                ]),
                if (d['title'] != null) Text(d['title'] as String, style: text.bodySmall),
                const SizedBox(height: 4),
                RatingLine(avg: asNum(d['rating_avg']), count: d['rating_count'] as int? ?? 0),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final s in specialties.take(3)) _Tag(s),
                  ...placeTags(d).map(_Tag.new),
                  if (d['is_full'] == true) _Tag(t('Fully booked'), warn: true),
                  if (d['is_my_dietitian'] == true) _Tag(t('Your dietitian'), strong: true),
                  if (d['my_request'] == 'pending') _Tag(t('Request sent'), strong: true),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

List<String> placeTags(Map<String, dynamic> d) => [
      if (d['city'] != null) d['city'] as String,
      if (d['works_online'] == true) t('Online'),
      if (d['works_in_person'] == true) t('In person'),
      if (d['years_experience'] != null) t('{0} years experience', [d['years_experience']]),
    ];

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.warn = false, this.strong = false});
  final String label;
  final bool warn;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final (bg, fg) = warn
        ? (s.errorContainer, s.onErrorContainer)
        : strong
            ? (s.primaryContainer, s.onPrimaryContainer)
            : (s.surfaceContainerHighest, s.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(fontSize: 12, color: fg)),
    );
  }
}

class Stars extends StatelessWidget {
  const Stars(this.value, {super.key, this.size = 16});
  final num value;
  final double size;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFF2B01E);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 1; i <= 5; i++)
        Icon(value >= i ? Icons.star_rounded : (value >= i - 0.5 ? Icons.star_half_rounded : Icons.star_outline_rounded),
            size: size, color: color),
    ]);
  }
}

class RatingLine extends StatelessWidget {
  const RatingLine({super.key, required this.avg, required this.count});
  final num? avg;
  final int count;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    if (count == 0 || avg == null) return Text(t('No ratings yet'), style: muted);
    return Row(children: [
      Stars(avg!),
      const SizedBox(width: 6),
      Text('${avg!.toStringAsFixed(1)} ', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      Text(t('({0} ratings)', [count]), style: muted),
    ]);
  }
}

// ---------------------------------------------------------------- detail
class DietitianDetailScreen extends StatefulWidget {
  const DietitianDetailScreen({super.key, required this.dietitianId});
  final String dietitianId;

  @override
  State<DietitianDetailScreen> createState() => _DietitianDetailScreenState();
}

class _DietitianDetailScreenState extends State<DietitianDetailScreen> {
  late Future<(Map<String, dynamic>?, List<Map<String, dynamic>>)> _future = _load();

  Future<(Map<String, dynamic>?, List<Map<String, dynamic>>)> _load() async {
    final all = await listDietitians();
    final d = all.where((r) => r['dietitian_id'] == widget.dietitianId).firstOrNull;
    final reviews = List<Map<String, dynamic>>.from(
        await db.rpc('dietitian_reviews', params: {'p_dietitian': widget.dietitianId}) as List);
    return (d, reviews);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _cancel() async {
    if (!await confirm(context, t('Cancel your request?'), t('The dietitian will no longer see it.'), ok: t('Cancel request'))) return;
    try {
      await db.rpc('cancel_dietitian_request');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Loader<(Map<String, dynamic>?, List<Map<String, dynamic>>)>(
        future: _future,
        builder: (context, data) {
          final (d, reviews) = data;
          if (d == null) return Center(child: EmptyHint(t('This dietitian is not listed any more.')));
          final text = Theme.of(context).textTheme;
          final specialties = List<String>.from(d['specialties'] as List? ?? const []);
          return ListView(padding: const EdgeInsets.all(16), children: [
            MaxWidth(
              width: 700,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(child: UserAvatar(url: d['photo_url'] as String?, name: d['full_name'] as String?, radius: 48)),
                const SizedBox(height: 12),
                Text(d['full_name'] as String? ?? '', style: text.headlineSmall, textAlign: TextAlign.center),
                if (d['title'] != null) Text(d['title'] as String, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Center(child: VerifiedBadge(status: 'approved')),
                const SizedBox(height: 8),
                Center(child: RatingLine(avg: asNum(d['rating_avg']), count: d['rating_count'] as int? ?? 0)),
                const SizedBox(height: 12),
                Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 6, children: [
                  for (final s in placeTags(d)) _Tag(s),
                  if (d['is_full'] == true) _Tag(t('Fully booked'), warn: true),
                ]),
                const SizedBox(height: 16),
                _action(d),
                const SizedBox(height: 16),
                if (d['bio'] != null) SectionCard(title: t('About'), child: Text(d['bio'] as String)),
                if (specialties.isNotEmpty)
                  SectionCard(
                    title: t('Specialties'),
                    child: Wrap(spacing: 6, runSpacing: 6, children: [for (final s in specialties) _Tag(s)]),
                  ),
                SectionCard(
                  title: t('Reviews'),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (reviews.isEmpty) EmptyHint(t('No reviews yet. Clients can rate a dietitian after 14 days together.')),
                    for (final r in reviews)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Stars(r['stars'] as int),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (r['comment'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(r['comment'] as String)),
                          Text(t('A client · {0}', [dateFmt.format(parseTs(r['created_at'])!)]), style: text.bodySmall),
                        ]),
                      ),
                  ]),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  Widget _action(Map<String, dynamic> d) {
    if (d['is_my_dietitian'] == true) {
      return Card(child: ListTile(leading: const Icon(Icons.check_circle_outline), title: Text(t('This is your dietitian.'))));
    }
    if (d['my_request'] == 'pending') {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.hourglass_top),
          title: Text(t('Request sent')),
          subtitle: Text(t('You\'ll get a notification when the dietitian answers.')),
          trailing: TextButton(onPressed: _cancel, child: Text(t('Cancel request'))),
        ),
      );
    }
    return FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      onPressed: () async {
        if (await sendDietitianRequest(context, d)) _reload();
      },
      icon: const Icon(Icons.handshake_outlined),
      label: Text(t('I want to work with this dietitian')),
    );
  }
}

/// Consent + optional message, then sends the request. True when sent.
Future<bool> sendDietitianRequest(BuildContext context, Map<String, dynamic> d) async {
  final consent = (await db.rpc('consent_info') as List).first as Map<String, dynamic>;
  final current = await db.from('client_links').select('dietitian_id').eq('client_id', myId).eq('status', 'active').maybeSingle();
  if (!context.mounted) return false;
  final sent = await Navigator.of(context).push<bool>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _RequestScreen(d: d, consent: consent, hasDietitian: current != null),
  ));
  return sent ?? false;
}

class _RequestScreen extends StatefulWidget {
  const _RequestScreen({required this.d, required this.consent, required this.hasDietitian});
  final Map<String, dynamic> d;
  final Map<String, dynamic> consent;
  final bool hasDietitian;

  @override
  State<_RequestScreen> createState() => _RequestScreenState();
}

class _RequestScreenState extends State<_RequestScreen> {
  final _message = TextEditingController();
  bool _agreed = false;
  bool _busy = false;

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await db.rpc('request_dietitian', params: {
        'p_dietitian': widget.d['dietitian_id'],
        'p_message': _message.text.trim(),
        'p_consent_version': widget.consent['consent_version'],
      });
      if (!mounted) return;
      showInfo(context, t('Request sent to {0}.', [widget.d['full_name']]));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final name = widget.d['full_name'] as String? ?? t('Dietitian');
    return Scaffold(
      appBar: AppBar(title: Text(t('Request to {0}', [name]))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        MaxWidth(
          width: 600,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.d['is_full'] == true)
              _Note(icon: Icons.event_busy, color: scheme.errorContainer,
                  text: t('{0} is fully booked right now. You can still send a request; they can accept it when a place opens up.', [name])),
            if (widget.hasDietitian)
              _Note(icon: Icons.swap_horiz, color: scheme.tertiaryContainer,
                  text: t('You already have a dietitian. If {0} accepts, you will leave your current dietitian automatically.', [name])),
            Text(t('Before accepting, {0} only sees your name and this message.', [name])),
            const SizedBox(height: 8),
            TextField(
              controller: _message,
              maxLines: 4,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t('Message (optional)'),
                hintText: t('e.g. your goal, or what you need help with'),
              ),
            ),
            const SizedBox(height: 8),
            Text(t('If they accept, your dietitian can see:'), style: text.titleMedium),
            for (final s in List<String>.from(widget.consent['shared_data'] as List))
              ListTile(dense: true, leading: const Icon(Icons.visibility_outlined), title: Text(tServer(s))),
            const SizedBox(height: 8),
            Text(t('If you leave'), style: text.titleMedium),
            for (final s in List<String>.from(widget.consent['after_leaving'] as List))
              ListTile(dense: true, leading: const Icon(Icons.info_outline), title: Text(tServer(s))),
            CheckboxListTile(
              value: _agreed,
              onChanged: (v) => setState(() => _agreed = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(t('I understand and agree to share this data with this dietitian if they accept.')),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _agreed && !_busy ? _send : null, child: Text(t('Send request'))),
            const SizedBox(height: 24),
          ]),
        ),
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
        color: color,
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(leading: Icon(icon), title: Text(text)),
      );
}

// ---------------------------------------------------------------- rating
/// Star rating with an optional comment. True when saved.
Future<bool> rateDietitian(BuildContext context, String dietitianId, String? name, {int? stars, String? comment}) async {
  var value = stars ?? 0;
  final ctrl = TextEditingController(text: comment ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(t('Rate {0}', [name ?? t('your dietitian')])),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                onPressed: () => set(() => value = i),
                icon: Icon(i <= value ? Icons.star_rounded : Icons.star_outline_rounded, size: 36, color: const Color(0xFFF2B01E)),
              ),
          ]),
          TextField(
            controller: ctrl,
            maxLines: 3,
            maxLength: 500,
            decoration: InputDecoration(hintText: t('What was it like? (optional)')),
          ),
          Text(t('Your review is shown without your name.'), style: Theme.of(c).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Cancel'))),
          FilledButton(onPressed: value == 0 ? null : () => Navigator.pop(c, true), child: Text(t('Save'))),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  try {
    await db.rpc('rate_dietitian', params: {'p_dietitian': dietitianId, 'p_stars': value, 'p_comment': ctrl.text.trim()});
    if (context.mounted) showInfo(context, t('Thanks for your rating!'));
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}
