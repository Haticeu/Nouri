import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/i18n.dart';
import '../../core/ui.dart';
import 'food.dart';

/// Search the food database and pick one food. Todo foods (no values yet) are
/// listed but can't be picked by clients. Returns null if cancelled.
Future<Food?> pickFood(BuildContext context, {String initialQuery = '', bool allowTodo = false}) =>
    Navigator.of(context).push<Food>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => FoodSearchScreen(initialQuery: initialQuery, allowTodo: allowTodo),
    ));

class FoodSearchScreen extends StatefulWidget {
  const FoodSearchScreen({super.key, this.initialQuery = '', this.allowTodo = false, this.onPick});
  final String initialQuery;
  final bool allowTodo;
  // When set (e.g. the dietitian Foods screen), tapping a food calls this instead of returning it.
  final void Function(Food food)? onPick;

  @override
  State<FoodSearchScreen> createState() => _FoodSearchScreenState();
}

class _FoodSearchScreenState extends State<FoodSearchScreen> {
  late final _query = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  List<Food> _results = [];
  bool _loading = false;
  Object? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _search);
  }

  Future<void> _search() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await searchFoods(_query.text, limit: 30);
      if (mounted && seq == _seq) setState(() => _results = r);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  void _choose(Food f) {
    if (widget.onPick != null) {
      widget.onPick!(f);
    } else {
      Navigator.pop(context, f);
    }
  }

  Future<void> _barcode() async {
    final food = await findByBarcode(context);
    if (food != null && mounted) _choose(food);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final short = _query.text.trim().length < 2;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('Find a food')),
        actions: [
          IconButton(tooltip: t('Barcode'), onPressed: _barcode, icon: const Icon(Icons.qr_code_scanner)),
        ],
      ),
      body: MaxWidth(
        width: 720,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _query,
              autofocus: true,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t('e.g. mercimek çorbası, yumurta, elma'),
                suffixIcon: _loading
                    ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
              ),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text(errorText(_error!)))
                : short
                    ? _hint(t('Type at least 2 letters. Turkish or English names both work, and typos are fine.'))
                    : _results.isEmpty && !_loading
                        ? _hint(t('No food found. Try another name, or scan the barcode of a packaged product.'))
                        : ListView.separated(
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: _results.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final f = _results[i];
                              final usable = f.hasValues || widget.allowTodo;
                              return ListTile(
                                enabled: usable,
                                onTap: usable ? () => _choose(f) : null,
                                title: Text(f.brand == null ? f.name : '${f.name} · ${f.brand}'),
                                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  const SizedBox(height: 2),
                                  Text(
                                    f.hasValues
                                        ? t('{0} kcal per 100 g · P {1} · C {2} · F {3}', [
                                            f.per100('kcal')!.round(),
                                            f.per100('protein')!.toStringAsFixed(1),
                                            f.per100('carbs')!.toStringAsFixed(1),
                                            f.per100('fat')!.toStringAsFixed(1),
                                          ])
                                        : t('No nutrition values yet: a dietitian needs to add them'),
                                    style: TextStyle(color: f.hasValues ? scheme.onSurfaceVariant : scheme.error),
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                    FoodSourceChip(f),
                                    if (f.portions.isNotEmpty)
                                      Text(f.portions.map((p) => p.label).toSet().take(4).join(' · '),
                                          style: Theme.of(context).textTheme.labelSmall),
                                  ]),
                                ]),
                                trailing: usable ? const Icon(Icons.chevron_right) : null,
                              );
                            },
                          ),
          ),
        ]),
      ),
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

// Phones and browsers (the web build reads the barcode from the webcam or phone camera).
bool get _hasCameraScanner => kIsWeb || (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// Scan with the camera (or type) a barcode, then look it up. Returns the food, or
/// null (with a message shown) if it isn't found or has incomplete values.
Future<Food?> findByBarcode(BuildContext context) async {
  final code = _hasCameraScanner
      ? await Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _ScanScreen()))
      : await _typeBarcode(context);
  if (code == null || code.isEmpty || !context.mounted) return null;
  final nav = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const _Busy()));
  try {
    final r = await lookupBarcode(code).whenComplete(nav.pop);
    if (!context.mounted) return null;
    if (r.food != null) return r.food;
    showInfo(
      context,
      r.reason == 'incomplete'
          ? t('{0} is in Open Food Facts but its nutrition values are incomplete. Search for a similar food instead.', [r.name ?? code])
          : t('No product found for barcode {0}. Search for the food by name instead.', [code]),
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
  return null;
}

Future<String?> _typeBarcode(BuildContext context) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(t('Enter barcode')),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(hintText: '8690000000000', helperText: t('The 8 to 14 digits under the barcode')),
        onSubmitted: (v) => Navigator.pop(c, v.replaceAll(RegExp(r'\D'), '')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.replaceAll(RegExp(r'\D'), '')), child: Text(t('Look up'))),
      ],
    ),
  );
}

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();

  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Scan barcode'))),
      body: Stack(children: [
        MobileScanner(
          controller: _controller,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.no_photography_outlined, size: 48, color: Colors.white70),
                const SizedBox(height: 12),
                Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? t('Camera permission was denied. Allow the camera for Nouri, or type the barcode.')
                      : t('No camera found. Type the barcode instead.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ]),
            ),
          ),
          onDetect: (capture) {
            final code = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
            if (code == null || _done) return;
            _done = true;
            Navigator.pop(context, code);
          },
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: Text(t('Point the camera at the barcode on the package.'))),
                TextButton(
                  onPressed: () async {
                    final code = await _typeBarcode(context);
                    if (code != null && code.isNotEmpty && context.mounted) Navigator.pop(context, code);
                  },
                  child: Text(t('Type it')),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy();

  @override
  Widget build(BuildContext context) => AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text(t('Looking up the product…'))),
        ]),
      );
}