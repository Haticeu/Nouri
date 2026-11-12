import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../core/i18n.dart';

/// In-app notification list. The same rows are what a future push sender
/// (Edge Function reading `notifications` + `device_tokens`) will deliver.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  static const _icons = {
    'message': Icons.chat_outlined,
    'change': Icons.history,
    'target_request': Icons.tune,
    'verification': Icons.verified_outlined,
    'link': Icons.link,
    'broadcast': Icons.campaign_outlined,
  };

  Future<void> _markAllRead() => db
      .from('notifications')
      .update({'read_at': DateTime.now().toUtc().toIso8601String()})
      .eq('user_id', myId)
      .isFilter('read_at', null);

  /// Message notification -> straight into the conversation.
  Future<void> _openChat(BuildContext context, String clientId, {required bool isClient}) async {
    if (!isClient) {
      context.push('/chat/$myId/$clientId');
      return;
    }
    // A client chats with their current dietitian.
    final link = await db.from('client_links').select('dietitian_id').eq('client_id', myId).eq('status', 'active').maybeSingle();
    if (!context.mounted) return;
    if (link == null) {
      showInfo(context, t('You are no longer connected to this dietitian.'));
      return;
    }
    context.push('/chat/${link['dietitian_id']}/$myId');
  }

  void _open(BuildContext context, Map<String, dynamic> n) {
    db.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', n['id']);
    final data = Map<String, dynamic>.from(n['data'] as Map? ?? const {});
    final clientId = data['client_id'] as String?;
    final isClient = clientId == myId;
    if (n['type'] == 'message' && clientId != null) {
      _openChat(context, clientId, isClient: isClient);
    } else if (n['type'] == 'verification' && data['submission_id'] != null) {
      context.push('/admin');
    } else if (clientId != null && !isClient && n['type'] != 'link') {
      context.push('/d/client/$clientId');
    } else {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('Notifications')),
        actions: [TextButton(onPressed: _markAllRead, child: Text(t('Mark all read')))],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: db.from('notifications').stream(primaryKey: ['id']).eq('user_id', myId).order('created_at', ascending: false).limit(100),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text(errorText(snap.error!)));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) return Center(child: Text(t('No notifications yet.')));
          return MaxWidth(
            width: 640,
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final n = items[i];
                final unread = n['read_at'] == null;
                return ListTile(
                  leading: Icon(_icons[n['type']] ?? Icons.notifications_outlined),
                  title: Text(tServer(n['title'] as String), style: TextStyle(fontWeight: unread ? FontWeight.bold : null)),
                  subtitle: Text([tServer(n['body'] as String?), dateTimeFmt.format(parseTs(n['created_at'])!)].whereType<String>().where((s) => s.isNotEmpty).join('\n')),
                  onTap: () => _open(context, n),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
