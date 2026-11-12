import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'i18n.dart';

final dateFmt = DateFormat('EEE d MMM');
final dateTimeFmt = DateFormat('d MMM y, HH:mm');
final isoDate = DateFormat('yyyy-MM-dd');

String today() => isoDate.format(DateTime.now());

String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// "breakfast" -> "Breakfast" / "Kahvaltı"
String mealName(String slot) => t(cap(slot));

DateTime? parseTs(dynamic v) => v == null ? null : DateTime.parse(v as String).toLocal();

num? asNum(dynamic v) => v == null ? null : (v is num ? v : num.tryParse(v.toString()));

String errorText(Object e) => switch (e) {
      PostgrestException(:final message) => tServer(message),
      AuthException(:final message) => tServer(message),
      StorageException(:final message) => message,
      FunctionException(:final details, :final status) =>
        (details is Map && details['error'] != null) ? tServer('${details['error']}') : t('Request failed ({0})', [status]),
      _ => e.toString(),
    };

void showError(BuildContext context, Object e) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
}

void showInfo(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

Future<bool> confirm(BuildContext context, String title, String body, {String? ok}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok ?? t('Confirm'))),
      ],
    ),
  );
  return result ?? false;
}

/// Ask for a single line/paragraph of text.
Future<String?> promptText(BuildContext context, String title,
    {String? hint, String initial = '', int maxLines = 1, String? ok}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: maxLines,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: Text(ok ?? t('Save'))),
      ],
    ),
  );
}

/// FutureBuilder with loading/error states and a reload hook.
class Loader<T> extends StatelessWidget {
  const Loader({super.key, required this.future, required this.builder});
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(errorText(snap.error!))));
        }
        // Check the state, not hasData: a completed Future<T?> may hold null.
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        return builder(context, snap.data as T);
      },
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.action});
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ?action,
            ]),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
      );
}

/// Constrains content width on desktop/web.
class MaxWidth extends StatelessWidget {
  const MaxWidth({super.key, required this.child, this.width = 900});
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) =>
      Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: width), child: child));
}
