import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';
import 'messages_screen.dart' show dietitianMessages;
import '../../core/i18n.dart';

typedef _Data = ({
  Map<String, dynamic> status,
  List<Map<String, dynamic>> clients,
  List<Map<String, dynamic>> requests,
  List<Map<String, dynamic>> former,
});

enum _Sort { name, lastLog, calories, streak, unread }

enum _Filter { all, noLog2Days, unread, overTarget }

/// One screen with every active client's status at a glance.
class ClientsOverviewScreen extends StatefulWidget {
  const ClientsOverviewScreen({super.key, required this.onOpenProfile});
  final VoidCallback onOpenProfile;

  @override
  State<ClientsOverviewScreen> createState() => _ClientsOverviewScreenState();
}

class _ClientsOverviewScreenState extends State<ClientsOverviewScreen> {
  late Future<_Data> _future = _load();
  _Sort _sort = _Sort.lastLog;
  _Filter _filter = _Filter.all;
  String _query = '';

  Future<_Data> _load() async {
    List<Map<String, dynamic>> rows(Object r) => List<Map<String, dynamic>>.from(r as List);
    final r = await Future.wait([
      db.rpc('my_workspace_status'),
      db.rpc('dietitian_client_overview'),
      db.rpc('my_connection_requests'),
      db.rpc('dietitian_former_clients'),
    ]);
    return (
      status: rows(r[0]).first,
      clients: rows(r[1]),
      requests: rows(r[2]),
      former: rows(r[3])..sort((a, b) => (b['ended_at'] as String).compareTo(a['ended_at'] as String)),
    );
  }

  Future<void> _answer(Map<String, dynamic> req, bool accept) async {
    final name = req['client_name'] as String? ?? t('this client');
    String? reason;
    if (accept) {
      final ok = await confirm(
        context,
        t('Accept {0}?', [name]),
        req['has_dietitian'] == true
            ? t('{0} currently has another dietitian and will leave them automatically. You will see their logs and profile from now on.', [name])
            : t('You will see their logs and profile from now on.'),
        ok: t('Accept'),
      );
      if (!ok) return;
    } else {
      reason = await promptText(context, t('Decline {0}?', [name]),
          hint: t('Reason for the client (optional), e.g. my list is full'), maxLines: 2, ok: t('Decline'));
      if (reason == null) return;
    }
    try {
      await db.rpc('respond_to_request', params: {'p_request': req['request_id'], 'p_accept': accept, 'p_reason': reason});
      if (mounted) showInfo(context, accept ? t('{0} is now your client.', [name]) : t('Request declined.'));
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _reload() => setState(() => _future = _load());

  List<Map<String, dynamic>> _apply(List<Map<String, dynamic>> rows) {
    final now = DateTime.now();
    bool matches(Map<String, dynamic> r) {
      if (_query.isNotEmpty && !((r['full_name'] as String?) ?? '').toLowerCase().contains(_query)) return false;
      final last = parseTs(r['last_log_at']);
      return switch (_filter) {
        _Filter.all => true,
        _Filter.noLog2Days => last == null || now.difference(last).inHours >= 48,
        _Filter.unread => (r['unread_messages'] as int) > 0,
        _Filter.overTarget =>
          r['target_calories'] != null && (asNum(r['today_calories']) ?? 0) > (r['target_calories'] as int),
      };
    }

    int cmp(Map<String, dynamic> a, Map<String, dynamic> b) => switch (_sort) {
          _Sort.name => ((a['full_name'] as String?) ?? '').compareTo((b['full_name'] as String?) ?? ''),
          // Least recently logged first: those are the clients needing attention.
          _Sort.lastLog => (parseTs(a['last_log_at']) ?? DateTime(1970)).compareTo(parseTs(b['last_log_at']) ?? DateTime(1970)),
          _Sort.calories => (asNum(b['today_calories']) ?? 0).compareTo(asNum(a['today_calories']) ?? 0),
          _Sort.streak => (b['logging_streak'] as int).compareTo(a['logging_streak'] as int),
          _Sort.unread => (b['unread_messages'] as int).compareTo(a['unread_messages'] as int),
        };
    return rows.where(matches).toList()..sort(cmp);
  }

  Future<void> _invite(Map<String, dynamic> status) async {
    // Only unverified dietitians have a limit (3); verified ones have none (null).
    final limit = status['client_limit'] as int?;
    if (limit != null && (status['active_clients'] as int) >= limit) {
      showInfo(context, t('Until your credential is approved you can have up to {0} active clients. Get verified to remove the limit.', [status['client_limit']]));
      return;
    }
    try {
      final row = await db.from('invites').insert({'dietitian_id': myId}).select('code, expires_at').single();
      if (!mounted) return;
      final code = row['code'] as String;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('Invite code')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t('Share this code with your client. They enter it in the "My Dietitian" tab.')),
            const SizedBox(height: 16),
            SelectableText(code, style: Theme.of(context).textTheme.displaySmall?.copyWith(letterSpacing: 4)),
            const SizedBox(height: 8),
            Text(t('Single use · expires {0}', [dateFmt.format(parseTs(row['expires_at'])!)])),
          ]),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              child: Text(t('Copy')),
            ),
            FilledButton(onPressed: () => Navigator.pop(c), child: Text(t('Done'))),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<_Data>(
      future: _future,
      builder: (context, data) => StreamBuilder<List<Map<String, dynamic>>>(
        // Unread counts come from the live message stream, so they clear as
        // soon as a conversation is read (here, in Messages, or on a phone).
        stream: _messages,
        builder: (context, snap) => _content(data, snap.data),
      ),
    );
  }

  late final Stream<List<Map<String, dynamic>>> _messages = dietitianMessages();

  Widget _content(_Data data, List<Map<String, dynamic>>? messages) {
        final status = data.status;
        final loaded = data.clients;
        final unread = <String, int>{};
        for (final m in messages ?? const <Map<String, dynamic>>[]) {
          if (m['sender_id'] != myId && m['read_at'] == null) {
            unread.update(m['client_id'] as String, (n) => n + 1, ifAbsent: () => 1);
          }
        }
        final all = messages == null
            ? loaded
            : [for (final r in loaded) {...r, 'unread_messages': unread[r['client_id']] ?? 0}];
        final rows = _apply(all);
        final wide = MediaQuery.sizeOf(context).width >= 1000;
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            _StatusBanner(status: status, onOpenProfile: widget.onOpenProfile),
            if (data.requests.isNotEmpty) _requests(data.requests, status),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 220,
                child: TextField(
                  decoration: InputDecoration(prefixIcon: Icon(Icons.search), hintText: t('Search clients'), isDense: true),
                  onChanged: (v) => setState(() => _query = v.toLowerCase()),
                ),
              ),
              DropdownButton<_Filter>(
                value: _filter,
                onChanged: (v) => setState(() => _filter = v!),
                items: [
                  DropdownMenuItem(value: _Filter.all, child: Text(t('All clients'))),
                  DropdownMenuItem(value: _Filter.noLog2Days, child: Text(t('Didn\'t log in 2 days'))),
                  DropdownMenuItem(value: _Filter.unread, child: Text(t('Unread messages'))),
                  DropdownMenuItem(value: _Filter.overTarget, child: Text(t('Over calorie target today'))),
                ],
              ),
              DropdownButton<_Sort>(
                value: _sort,
                onChanged: (v) => setState(() => _sort = v!),
                items: [
                  DropdownMenuItem(value: _Sort.lastLog, child: Text(t('Sort: last log (oldest first)'))),
                  DropdownMenuItem(value: _Sort.name, child: Text(t('Sort: name'))),
                  DropdownMenuItem(value: _Sort.calories, child: Text(t('Sort: calories today'))),
                  DropdownMenuItem(value: _Sort.streak, child: Text(t('Sort: streak'))),
                  DropdownMenuItem(value: _Sort.unread, child: Text(t('Sort: unread'))),
                ],
              ),
              FilledButton.icon(onPressed: () => _invite(status), icon: const Icon(Icons.person_add_alt), label: Text(t('Invite client'))),
            ]),
            const SizedBox(height: 12),
            if (all.isEmpty)
              EmptyHint(t('No active clients yet. Clients can find you in "Find a dietitian" once you are verified, or you can share an invite code.'))
            else if (rows.isEmpty)
              EmptyHint(t('No clients match this filter.'))
            else if (wide)
              _table(rows)
            else
              for (final r in rows) _card(r),
            if (data.former.isNotEmpty) _inactive(data.former),
          ]),
        );
  }

  Widget _requests(List<Map<String, dynamic>> requests, Map<String, dynamic> status) {
    final limit = status['client_limit'] as int?;
    final full = limit != null && (status['active_clients'] as int) >= limit;
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.person_add_alt_1_outlined),
            const SizedBox(width: 8),
            Expanded(child: Text(t('Requests from new clients ({0})', [requests.length]), style: Theme.of(context).textTheme.titleMedium)),
          ]),
          if (full)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t('Your list is full. To accept, raise your capacity in Workspace or end a client.')),
            ),
          for (final q in requests)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: UserAvatar(url: q['client_avatar'] as String?, name: q['client_name'] as String?),
              title: Text(q['client_name'] as String? ?? t('Unnamed')),
              subtitle: Text([
                if (q['message'] != null) '"${q['message']}"',
                dateTimeFmt.format(parseTs(q['created_at'])!),
                if (q['has_dietitian'] == true) t('has another dietitian now'),
              ].join(' · ')),
              trailing: Wrap(spacing: 4, children: [
                TextButton(onPressed: () => _answer(q, false), child: Text(t('Decline'))),
                FilledButton(onPressed: full ? null : () => _answer(q, true), child: Text(t('Accept'))),
              ]),
            ),
        ]),
      ),
    );
  }

  /// Clients who left: kept in the list as inactive. Opening one shows only
  /// what the dietitian keeps (their private notes and the plans they wrote).
  Widget _inactive(List<Map<String, dynamic>> former) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Card(
          child: ExpansionTile(
            leading: const Icon(Icons.person_off_outlined),
            title: Text(t('Inactive clients ({0})', [former.length])),
            subtitle: Text(t('They left or were removed. Only your notes and plans are kept.')),
            children: [
              for (final f in former)
                ListTile(
                  onTap: () => context.push('/d/client/${f['client_id']}').then((_) => _reload()),
                  leading: UserAvatar(url: null, name: f['client_name'] as String?),
                  title: Row(children: [
                    Flexible(child: Text(f['client_name'] as String? ?? t('Former client'))),
                    const SizedBox(width: 8),
                    const _InactiveChip(),
                  ]),
                  subtitle: Text('${dateFmt.format(parseTs(f['started_at'])!)} – ${dateFmt.format(parseTs(f['ended_at'])!)}'),
                  trailing: const Icon(Icons.chevron_right),
                ),
            ],
          ),
        ),
      );

  void _open(Map<String, dynamic> r) => context.push('/d/client/${r['client_id']}').then((_) => _reload());

  Widget _trend(String? t) => switch (t) {
        'up' => const Icon(Icons.trending_up, color: Colors.orange),
        'down' => const Icon(Icons.trending_down, color: Colors.green),
        'flat' => const Icon(Icons.trending_flat),
        _ => const Text('–'),
      };

  String _lastLog(dynamic ts) {
    final at = parseTs(ts);
    if (at == null) return t('Never');
    final h = DateTime.now().difference(at).inHours;
    if (h < 1) return t('Just now');
    if (h < 24) return t('{0}h ago', [h]);
    return t('{0}d ago', [h ~/ 24]);
  }

  Widget _kcal(Map<String, dynamic> r) {
    final kcal = (asNum(r['today_calories']) ?? 0).round();
    final target = r['target_calories'] as int?;
    final over = target != null && kcal > target;
    return Text(target == null ? '$kcal' : '$kcal / $target',
        style: TextStyle(color: over ? Theme.of(context).colorScheme.error : null));
  }

  /// Unread count; tapping it opens that client's conversation directly.
  Widget _unread(Map<String, dynamic> r) {
    final n = r['unread_messages'] as int;
    if (n == 0) return const Text('–');
    return IconButton(
      tooltip: t('Open messages'),
      onPressed: () => context.push('/chat/$myId/${r['client_id']}').then((_) => _reload()),
      icon: Badge(label: Text('$n'), child: const Icon(Icons.mail_outline)),
    );
  }

  Widget _table(List<Map<String, dynamic>> rows) => Card(
        child: DataTable(
          showCheckboxColumn: false,
          columns: [
            DataColumn(label: Text(t('Client'))),
            DataColumn(label: Text(t('Last log'))),
            DataColumn(label: Text(t('Today kcal'))),
            DataColumn(label: Text(t('Weight'))),
            DataColumn(label: Text(t('Streak'))),
            DataColumn(label: Text(t('Unread'))),
          ],
          rows: [
            for (final r in rows)
              DataRow(onSelectChanged: (_) => _open(r), cells: [
                DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                  UserAvatar(url: r['avatar_url'] as String?, name: r['full_name'] as String?, radius: 16),
                  const SizedBox(width: 10),
                  Text(r['full_name'] as String? ?? t('Unnamed')),
                ])),
                DataCell(Text(_lastLog(r['last_log_at']))),
                DataCell(_kcal(r)),
                DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(r['latest_weight_kg'] == null ? '' : '${asNum(r['latest_weight_kg'])} kg  '),
                  _trend(r['weight_trend'] as String?),
                ])),
                DataCell(Text(t('{0} d', [r['logging_streak']]))),
                DataCell(_unread(r)),
              ]),
          ],
        ),
      );

  Widget _card(Map<String, dynamic> r) => Card(
        child: ListTile(
          onTap: () => _open(r),
          leading: UserAvatar(url: r['avatar_url'] as String?, name: r['full_name'] as String?),
          title: Text(r['full_name'] as String? ?? t('Unnamed')),
          subtitle: Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(t('Logged {0}', [_lastLog(r['last_log_at'])])),
            _kcal(r),
            Text(t('🔥 {0}d', [r['logging_streak']])),
          ]),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            _trend(r['weight_trend'] as String?),
            const SizedBox(width: 8),
            _unread(r),
          ]),
        ),
      );
}

class _InactiveChip extends StatelessWidget {
  const _InactiveChip();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
      child: Text(t('Inactive'), style: TextStyle(fontSize: 11, color: s.onSurfaceVariant)),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status, required this.onOpenProfile});
  final Map<String, dynamic> status;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final v = status['verification_status'] as String;
    final limit = status['client_limit'] as int?;
    final capacity = limit == null
        ? t('{0} active clients', [status['active_clients']])
        : t('{0} of {1} active clients', [status['active_clients'], limit]);
    if (v == 'approved') {
      return Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(capacity));
    }
    final (msg, action) = switch (v) {
      'pending' => (t('Your credential is being reviewed. Until it is approved, clients see an "Unverified" badge and you can have up to 3 clients.'), null),
      'rejected' => (t('Your credential was not approved: {0}. Upload a new document to try again.', [status['last_review_note'] ?? '']), t('Upload again')),
      _ => (t('Upload your diploma or certificate to get verified. Until then, clients see an "Unverified" badge and you can have up to 3 clients.'), t('Upload now')),
    };
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const Icon(Icons.verified_user_outlined),
        title: Text(msg),
        subtitle: Text(capacity),
        trailing: action == null ? null : FilledButton(onPressed: onOpenProfile, child: Text(action)),
      ),
    );
  }
}
