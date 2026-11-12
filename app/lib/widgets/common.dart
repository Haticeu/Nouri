import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import '../core/ui.dart';
import '../core/i18n.dart';

class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, required this.status});
  final String? status;

  @override
  Widget build(BuildContext context) {
    final verified = status == 'approved';
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: verified
          ? t('Credentials checked by Nouri')
          : t('This dietitian\'s credentials have not been verified by Nouri yet'),
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(verified ? Icons.verified : Icons.help_outline,
            size: 16, color: verified ? scheme.primary : scheme.error),
        label: Text(verified ? t('Verified') : t('Unverified')),
      ),
    );
  }
}

/// Profile photo, or initials on a colour derived from the name.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.url, required this.name, this.radius = 20});
  final String? url;
  final String? name;
  final double radius;

  static String initials(String? name) {
    final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty && !p.endsWith('.')).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = [scheme.primaryContainer, scheme.secondaryContainer, scheme.tertiaryContainer];
    final bg = palette[(name ?? '').codeUnits.fold<int>(0, (a, b) => a + b) % palette.length];
    final hasPhoto = url != null && url!.isNotEmpty;
    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      foregroundImage: hasPhoto ? NetworkImage(url!) : null,
      child: Text(initials(name), style: TextStyle(fontSize: radius * 0.75, fontWeight: FontWeight.w600)),
    );
  }
}

/// App-bar bell with live unread count.
class NotificationsButton extends StatelessWidget {
  const NotificationsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: db.from('notifications').stream(primaryKey: ['id']).eq('user_id', myId),
      builder: (context, snap) {
        final unread = (snap.data ?? const []).where((n) => n['read_at'] == null).length;
        return IconButton(
          tooltip: t('Notifications'),
          onPressed: () => context.push('/notifications'),
          icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_outlined)),
        );
      },
    );
  }
}

/// Top-right profile photo with the account menu.
class AccountMenu extends StatelessWidget {
  const AccountMenu({super.key, required this.session});
  final AppSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: PopupMenuButton<String>(
          tooltip: t('Account'),
          offset: const Offset(0, 48),
          onSelected: (v) {
            if (v == 'profile') context.push('/profile');
            if (v == 'admin') context.push('/admin');
            if (v == 'out') session.signOut();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(url: session.avatarUrl, name: session.fullName),
                title: Text(session.fullName ?? t('Your account')),
                subtitle: Text(session.email ?? ''),
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'profile',
              child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.person_outline), title: Text(t('Profile & settings'))),
            ),
            if (session.isAdmin)
              PopupMenuItem(
                value: 'admin',
                child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.verified_user_outlined), title: Text(t('Admin: verifications'))),
              ),
            PopupMenuItem(
              value: 'out',
              child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.logout), title: Text(t('Sign out'))),
            ),
          ],
          child: UserAvatar(url: session.avatarUrl, name: session.fullName, radius: 17),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Broadcasts

/// Visual identity per post category, shared by dietitian and client screens.
({IconData icon, String label, Color color, Color onColor}) broadcastStyle(BuildContext context, String? category) {
  final s = Theme.of(context).colorScheme;
  return switch (category) {
    'recipe' => (icon: Icons.restaurant_menu, label: t('Recipe'), color: s.primaryContainer, onColor: s.onPrimaryContainer),
    'announcement' => (icon: Icons.campaign_outlined, label: t('Announcement'), color: s.secondaryContainer, onColor: s.onSecondaryContainer),
    _ => (icon: Icons.lightbulb_outline, label: t('Tip'), color: s.tertiaryContainer, onColor: s.onTertiaryContainer),
  };
}

/// A general post from a dietitian to all their clients.
class BroadcastCard extends StatelessWidget {
  const BroadcastCard({super.key, required this.post, this.compact = false, this.author, this.onDelete});
  final Map<String, dynamic> post;
  final bool compact;
  final String? author;
  final VoidCallback? onDelete;

  void _open(BuildContext context) => showDialog<void>(
        context: context,
        builder: (c) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(child: BroadcastCard(post: post, author: author)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final st = broadcastStyle(context, post['category'] as String?);
    final text = Theme.of(context).textTheme;
    final created = parseTs(post['created_at']);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: compact ? () => _open(context) : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: st.color,
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(children: [
              Icon(st.icon, color: st.onColor, size: 20),
              const SizedBox(width: 8),
              Text(st.label, style: text.labelLarge?.copyWith(color: st.onColor)),
              const SizedBox(width: 8),
              Text(t('· for all clients'), style: text.labelMedium?.copyWith(color: st.onColor.withValues(alpha: 0.75))),
              const Spacer(),
              if (created != null) Text(dateFmt.format(created), style: text.labelMedium?.copyWith(color: st.onColor)),
              if (onDelete != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: t('Delete'),
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline, color: st.onColor, size: 20),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(post['title'] as String, style: text.titleMedium),
              const SizedBox(height: 6),
              Text(
                post['body'] as String,
                maxLines: compact ? 2 : null,
                overflow: compact ? TextOverflow.ellipsis : null,
              ),
              if (compact)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(t('Read more'), style: text.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
                ),
              if (author != null && !compact)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text('— $author', style: text.labelLarge),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
