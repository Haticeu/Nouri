import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';
import '../../core/i18n.dart';

/// Dietitian posts general tips, recipes and announcements to all current
/// clients at once. Personal advice stays in each client's Notes tab.
class BroadcastsScreen extends StatefulWidget {
  const BroadcastsScreen({super.key});

  @override
  State<BroadcastsScreen> createState() => _BroadcastsScreenState();
}

class _BroadcastsScreenState extends State<BroadcastsScreen> {
  late Future<(List<Map<String, dynamic>>, int)> _future = _load();
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _category = 'tip';
  bool _posting = false;

  Future<(List<Map<String, dynamic>>, int)> _load() async {
    final posts = await db.from('broadcasts').select().eq('dietitian_id', myId).order('created_at', ascending: false);
    final status = (await db.rpc('my_workspace_status') as List).first as Map;
    return (posts, status['active_clients'] as int);
  }

  Future<void> _post(int audience) async {
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      showInfo(context, t('Add a title and a message.'));
      return;
    }
    final ok = await confirm(
      context,
      t('Share with all clients?'),
      t('This {0} will be visible to your {1} current client{2}, who will also get a notification.', [broadcastStyle(context, _category).label.toLowerCase(), audience, audience == 1 ? '' : 's']),
      ok: t('Share'),
    );
    if (!ok) return;
    setState(() => _posting = true);
    try {
      await db.from('broadcasts').insert({
        'dietitian_id': myId,
        'category': _category,
        'title': _title.text.trim(),
        'body': _body.text.trim(),
      });
      _title.clear();
      _body.clear();
      setState(() => _future = _load());
      if (mounted) showInfo(context, t('Shared with {0} client{1}.', [audience, audience == 1 ? '' : 's']));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> post) async {
    if (!await confirm(context, t('Delete this post?'), t('Clients will no longer see it.'), ok: t('Delete'))) return;
    try {
      await db.from('broadcasts').delete().eq('id', post['id']);
      setState(() => _future = _load());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<(List<Map<String, dynamic>>, int)>(
      future: _future,
      builder: (context, data) {
        final (posts, audience) = data;
        final style = broadcastStyle(context, _category);
        final text = Theme.of(context).textTheme;
        return ListView(padding: const EdgeInsets.all(16), children: [
          MaxWidth(
            width: 760,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    color: style.color,
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Icon(style.icon, color: style.onColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(t('Share something with all your clients'),
                            style: text.titleMedium?.copyWith(color: style.onColor)),
                      ),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(value: 'tip', icon: Icon(Icons.lightbulb_outline), label: Text(t('Tip'))),
                          ButtonSegment(value: 'recipe', icon: Icon(Icons.restaurant_menu), label: Text(t('Recipe'))),
                          ButtonSegment(value: 'announcement', icon: Icon(Icons.campaign_outlined), label: Text(t('Announcement'))),
                        ],
                        selected: {_category},
                        onSelectionChanged: (s) => setState(() => _category = s.first),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _title,
                        maxLength: 120,
                        decoration: InputDecoration(
                          labelText: t('Title'),
                          hintText: switch (_category) {
                            'recipe' => t('e.g. High-protein lentil salad'),
                            'announcement' => t('e.g. Clinic closed on Friday'),
                            _ => t('e.g. Start the day with protein'),
                          },
                        ),
                      ),
                      TextField(
                        controller: _body,
                        minLines: 4,
                        maxLines: 10,
                        maxLength: 4000,
                        decoration: InputDecoration(labelText: t('Message'), alignLabelWithHint: true),
                      ),
                      Row(children: [
                        Expanded(
                          child: Text(
                            t('General advice for everyone. For personal advice, use a client\'s Notes tab.'),
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: _posting || audience == 0 ? null : () => _post(audience),
                          icon: const Icon(Icons.send),
                          label: Text(audience == 0 ? t('No clients yet') : t('Share with {0}', [audience])),
                        ),
                      ]),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 20),
              Text(t('Shared so far'), style: text.titleMedium),
              const SizedBox(height: 8),
              if (posts.isEmpty) EmptyHint(t('Nothing shared yet.')),
              for (final p in posts) BroadcastCard(post: p, onDelete: () => _delete(p)),
            ]),
          ),
        ]);
      },
    );
  }
}
