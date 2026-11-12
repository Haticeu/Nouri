import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/session.dart';
import '../../core/ui.dart';
import '../chat/chat_screen.dart';

/// Messages the client can see (with their current and former dietitians).
Stream<List<Map<String, dynamic>>> clientMessages() =>
    db.from('messages').stream(primaryKey: ['id']).eq('client_id', myId).order('created_at', ascending: false);

/// The client's Messages tab: the chat with their dietitian.
class ClientMessagesTab extends StatefulWidget {
  const ClientMessagesTab({super.key});

  @override
  State<ClientMessagesTab> createState() => _ClientMessagesTabState();
}

class _ClientMessagesTabState extends State<ClientMessagesTab> {
  late final Future<Map<String, dynamic>?> _link =
      db.from('client_links').select('dietitian_id').eq('client_id', myId).eq('status', 'active').maybeSingle();

  @override
  Widget build(BuildContext context) {
    return Loader<Map<String, dynamic>?>(
      future: _link,
      builder: (context, link) {
        if (link != null) {
          return ChatScreen(dietitianId: link['dietitian_id'] as String, clientId: myId, embedded: true);
        }
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.forum_outlined, size: 56),
              const SizedBox(height: 12),
              Text(t('No messages yet'), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(t('Once you work with a dietitian, you can message them here.'), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => context.push('/dietitians'),
                icon: const Icon(Icons.search),
                label: Text(t('Find a dietitian')),
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// Navigation icon with the number of unread messages from the dietitian.
class ClientUnreadIcon extends StatefulWidget {
  const ClientUnreadIcon({super.key, required this.selected});
  final bool selected;

  @override
  State<ClientUnreadIcon> createState() => _ClientUnreadIconState();
}

class _ClientUnreadIconState extends State<ClientUnreadIcon> {
  late final Stream<List<Map<String, dynamic>>> _stream = clientMessages();

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        // Only the current dietitian's thread opens in the tab, so count only
        // messages that the dietitian can still reach (the newest thread).
        final msgs = snap.data ?? const <Map<String, dynamic>>[];
        final current = msgs.isEmpty ? null : msgs.first['dietitian_id'];
        final unread = msgs.where((m) => m['dietitian_id'] == current && m['sender_id'] != myId && m['read_at'] == null).length;
        return Badge(
          isLabelVisible: unread > 0,
          label: Text('$unread'),
          child: Icon(selected ? Icons.chat_bubble : Icons.chat_bubble_outline),
        );
      },
    );
  }
}
