import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../core/i18n.dart';

/// 1:1 chat between a dietitian and a client (realtime, text + photos).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.dietitianId, required this.clientId, this.embedded = false});
  final String dietitianId;
  final String clientId;

  /// Inside a tab that already has an app bar (the client's Messages tab).
  final bool embedded;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _photoUrls = <String, Future<String>>{};
  late final Stream<List<Map<String, dynamic>>> _stream = db
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('client_id', widget.clientId)
      .order('created_at', ascending: true);
  String? _otherName;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final otherId = myId == widget.clientId ? widget.dietitianId : widget.clientId;
    db.from('profiles').select('full_name').eq('id', otherId).maybeSingle().then((p) {
      if (mounted) setState(() => _otherName = p?['full_name'] as String?);
    });
  }

  Future<void> _markRead(List<Map<String, dynamic>> msgs) async {
    if (!msgs.any((m) => m['sender_id'] != myId && m['read_at'] == null)) return;
    await db
        .from('messages')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('client_id', widget.clientId)
        .eq('dietitian_id', widget.dietitianId)
        .neq('sender_id', myId)
        .isFilter('read_at', null);
  }

  Future<void> _send({XFile? photo}) async {
    final body = _text.text.trim();
    if (body.isEmpty && photo == null) return;
    setState(() => _sending = true);
    try {
      String? path;
      if (photo != null) {
        path = '${widget.clientId}/${DateTime.now().millisecondsSinceEpoch}.jpg';
        await db.storage.from('message-photos').uploadBinary(path, await photo.readAsBytes());
      }
      await db.from('messages').insert({
        'dietitian_id': widget.dietitianId,
        'client_id': widget.clientId,
        'sender_id': myId,
        'body': body.isEmpty ? null : body,
        'photo_path': path,
      });
      _text.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<String> _photoUrl(String path) =>
      _photoUrls.putIfAbsent(path, () => db.storage.from('message-photos').createSignedUrl(path, 3600));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: Text(_otherName ?? t('Messages'))),
      body: Column(children: [
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _stream,
            builder: (context, snap) {
              if (snap.hasError) return Center(child: Text(errorText(snap.error!)));
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              // A client may have older threads with former dietitians; show only this pair.
              final msgs = snap.data!.where((m) => m['dietitian_id'] == widget.dietitianId).toList();
              _markRead(msgs);
              if (msgs.isEmpty) return Center(child: Text(t('Say hello 👋')));
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: msgs.length,
                itemBuilder: (context, i) {
                  final m = msgs[msgs.length - 1 - i];
                  final mine = m['sender_id'] == myId;
                  return Align(
                    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 420),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (m['photo_path'] != null)
                          FutureBuilder<String>(
                            future: _photoUrl(m['photo_path'] as String),
                            builder: (_, s) => s.hasData
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(s.data!, height: 200, fit: BoxFit.cover),
                                  )
                                : const SizedBox(height: 60, width: 60, child: Center(child: CircularProgressIndicator())),
                          ),
                        if (m['body'] != null) Text(m['body'] as String),
                        const SizedBox(height: 2),
                        Text(
                          '${dateTimeFmt.format(parseTs(m['created_at'])!)}${mine && m['read_at'] != null ? ' · ${t('Read')}' : ''}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ]),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(children: [
              IconButton(
                tooltip: t('Send photo'),
                onPressed: _sending
                    ? null
                    : () async {
                        final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 80);
                        if (x != null) _send(photo: x);
                      },
                icon: const Icon(Icons.photo_outlined),
              ),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(hintText: t('Message'), border: OutlineInputBorder()),
                ),
              ),
              IconButton(onPressed: _sending ? null : () => _send(), icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}
