import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart' show RichTextEditingController;
import 'package:PiliPlus/common/widgets/flutter/text_field/text_field.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:material_ui/material_ui.dart';

class SvFilterSettings extends StatefulWidget {
  const SvFilterSettings({super.key});

  @override
  State<SvFilterSettings> createState() => _SvFilterSettingsState();
}

class _SvFilterSettingsState extends State<SvFilterSettings> {
  final RichTextEditingController _inputController = RichTextEditingController();
  List<String> _keywords = [];

  @override
  void initState() {
    super.initState();
    _keywords = List<String>.from(
        GStorage.localCache.get(LocalCacheKey.svTitleKeywords, defaultValue: <String>[]));
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _add() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _keywords.add(text);
      _inputController.clear();
    });
    GStorage.localCache.put(LocalCacheKey.svTitleKeywords, _keywords);
  }

  void _remove(String keyword) {
    setState(() {
      _keywords.remove(keyword);
    });
    GStorage.localCache.put(LocalCacheKey.svTitleKeywords, _keywords);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('屏蔽词管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: RichTextField(
                  controller: _inputController,
                  decoration: const InputDecoration(
                    hintText: '输入标题关键词',
                    filled: true,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: Theme.of(context).colorScheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _add,
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.add, color: Colors.white, size: 22),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_keywords.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: Text('暂无屏蔽词')),
            )
          else
            ..._keywords.map(
              (k) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.block, size: 18, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: 10),
                    Expanded(child: Text(k)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => _remove(k),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
