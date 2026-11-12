import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';
import '../chat/chat_screen.dart';
import '../../core/i18n.dart';

/// Live stream of every message the dietitian can see (RLS: active clients only).
Stream<List<Map<String, dynamic>>> dietitianMessages() =>
    db.from('messages').stream(primaryKey: ['id']).eq('dietitian_id', myId).order('created_at', ascending: false);

/// Dietitian inbox: one row per client conversation, newest first, with unread
/// counts. On wide screens the selected conversation opens beside the list.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  late final Future<List<Map<String, dynamic>>> _clients =
      db.rpc('dietitian_client_overview').then((r) => List<Map<String, dynamic>>.from(r as List));
  late final Stream<List<Map<String, dynamic>>> _messages = dietitianMessages();
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    return Loader<List<Map<String, dynamic>>>(
      future: _clients,
      builder: (context, clients) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _messages,
        builder: (context, snap) {
          final msgs = snap.data ?? const [];
          final threads = _threads(clients, msgs);
          final list = _list(threads, wide);
          if (!wide) return list;
          return Row(children: [
            SizedBox(width: 360, child: list),
            const VerticalDivider(width: 1),
            Expanded(
              child: _selected == null
                  ? Center(child: EmptyHint(t('Choose a conversation.')))
                  : ChatScreen(key: ValueKey(_selected), dietitianId: myId, clientId: _selected!),
            ),
          ]);
        },
      ),
    );
  }

  /// Every active client, with their latest message and unread count.
  List<({Map<String, dynamic> client, Map<String, dynamic>? last, int unread})> _threads(
      List<Map<String, dynamic>> clients, List<Map<String, dynamic>> msgs) {
    final threads = [
      for (final c in clients)
        (
          client: c,
          last: msgs.where((m) => m['client_id'] == c['client_id']).firstOrNull,
          unread: msgs.where((m) => m['client_id'] == c['client_id'] && m['sender_id'] != myId && m['read_at'] == null).length,
        ),
    ];
    // Conversations with messages first (newest on top), then everyone else by name.
    threads.sort((a, b) {
      final ta = a.last?['created_at'] as String?;
      final tb = b.last?['created_at'] as String?;
      if (ta != null && tb != null) return tb.compareTo(ta);
      if (ta != null) return -1;
      if (tb != null) return 1;
      return ((a.client['full_name'] as String?) ?? '').compareTo((b.client['full_name'] as String?) ?? '');
    });
    return threads;
  }

  Widget _list(List<({Map<String, dynamic> client, Map<String, dynamic>? last, int unread})> threads, bool wide) {
    if (threads.isEmpty) return Center(child: EmptyHint(t('No clients yet. Invite a client to start messaging.')));
    final text = Theme.of(context).textTheme;
    return ListView.separated(
      itemCount: threads.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final th = threads[i];
        final id = th.client['client_id'] as String;
        final last = th.last;
        final preview = last == null
            ? t('No messages yet. Say hello!')
            : '${last['sender_id'] == myId ? 'You: ' : ''}${last['body'] ?? '📷 Photo'}';
        final bold = th.unread > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null;
        return ListTile(
          selected: wide && _selected == id,
          leading: UserAvatar(url: th.client['avatar_url'] as String?, name: th.client['full_name'] as String?),
          title: Text(th.client['full_name'] as String? ?? t('Unnamed'), style: bold),
          subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: bold),
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (last != null) Text(_when(parseTs(last['created_at'])!), style: text.labelSmall),
            if (th.unread > 0) ...[
              const SizedBox(height: 4),
              Badge(label: Text('${th.unread}')),
            ],
          ]),
          onTap: () => wide ? setState(() => _selected = id) : context.push('/chat/$myId/$id'),
        );
      },
    );
  }

  String _when(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    return dateFmt.format(t);
  }
}

/// Navigation icon with the dietitian's total unread message count.
class UnreadMessagesIcon extends StatelessWidget {
  const UnreadMessagesIcon({super.key, required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: dietitianMessages(),
      builder: (context, snap) {
        final unread = (snap.data ?? const []).where((m) => m['sender_id'] != myId && m['read_at'] == null).length;
        return Badge(
          isLabelVisible: unread > 0,
          label: Text('$unread'),
          child: Icon(selected ? Icons.chat : Icons.chat_outlined),
        );
      },
    );
  }
}
