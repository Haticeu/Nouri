import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';
import '../../core/i18n.dart';

/// Invite code entry followed by the consent screen.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _code = TextEditingController();
  Map<String, dynamic>? _preview;
  bool _agreed = false;
  bool _busy = false;

  Future<void> _lookup() async {
    setState(() => _busy = true);
    try {
      final rows = await db.rpc('get_invite_preview', params: {'p_code': _code.text.trim()}) as List;
      if (rows.isEmpty) {
        if (mounted) showInfo(context, t('That code is invalid, already used, or expired.'));
      } else {
        setState(() => _preview = Map<String, dynamic>.from(rows.first as Map));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await db.rpc('accept_invite', params: {
        'p_code': _code.text.trim(),
        // The version of the text the client just read; the server rejects stale versions.
        'p_consent_version': _preview!['consent_version'],
      });
      if (mounted) {
        showInfo(context, t('You\'re connected with {0}.', [_preview!['full_name']]));
        context.pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_preview == null ? t('Join a dietitian') : t('Review and consent'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: MaxWidth(width: 560, child: _preview == null ? _codeStep() : _consentStep()),
      ),
    );
  }

  Widget _codeStep() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t('Enter the invite code your dietitian gave you.')),
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: t('Invite code'), hintText: 'e.g. 7F3A9C21'),
          onSubmitted: (_) => _lookup(),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _lookup, child: Text(t('Continue'))),
      ]);

  Widget _consentStep() {
    final p = _preview!;
    final text = Theme.of(context).textTheme;
    final verified = p['verified'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundImage: p['photo_url'] != null ? NetworkImage(p['photo_url'] as String) : null,
            child: p['photo_url'] == null ? const Icon(Icons.person) : null,
          ),
          title: Text(p['full_name'] as String? ?? t('Dietitian')),
          subtitle: Text(p['title'] as String? ?? ''),
          trailing: VerifiedBadge(status: verified ? 'approved' : 'pending'),
        ),
      ),
      if (!verified)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            t('Nouri has not yet verified this dietitian\'s credentials.'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 16),
      Text(t('While you are connected, your dietitian can see:'), style: text.titleMedium),
      for (final s in List<String>.from(p['shared_data'] as List))
        ListTile(dense: true, leading: const Icon(Icons.visibility_outlined), title: Text(tServer(s))),
      ListTile(
        dense: true,
        leading: Icon(Icons.visibility_off_outlined),
        title: Text(t('They never see other clients\' data, and other clients never see yours.')),
      ),
      const SizedBox(height: 8),
      Text(t('If you leave'), style: text.titleMedium),
      for (final s in List<String>.from(p['after_leaving'] as List))
        ListTile(dense: true, leading: const Icon(Icons.info_outline), title: Text(tServer(s))),
      const SizedBox(height: 8),
      CheckboxListTile(
        value: _agreed,
        onChanged: (v) => setState(() => _agreed = v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(t('I understand and agree to share this data with this dietitian.')),
      ),
      const SizedBox(height: 8),
      FilledButton(onPressed: _agreed && !_busy ? _accept : null, child: Text(t('Join'))),
      TextButton(onPressed: () => setState(() => _preview = null), child: Text(t('Back'))),
    ]);
  }
}
