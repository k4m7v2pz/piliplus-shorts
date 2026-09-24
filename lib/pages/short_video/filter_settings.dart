import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SvFilterSettings extends StatefulWidget {
  const SvFilterSettings({super.key});

  @override
  State<SvFilterSettings> createState() => _SvFilterSettingsState();
}

class _SvFilterSettingsState extends State<SvFilterSettings>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  static const _tabs = ['标题', 'UP主昵称', 'BGM'];
  static const _keys = [
    LocalCacheKey.svTitleKeywords,
    LocalCacheKey.svNewsKeywords,
    LocalCacheKey.svMusicKeywords,
  ];

  List<List<String>> _lists = [[], [], []];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    for (var i = 0; i < 3; i++) {
      _lists[i] = List<String>.from(
          GStorage.localCache.get(_keys[i], defaultValue: <String>[]));
    }
  }

  void _save(int tab) {
    GStorage.localCache.put(_keys[tab], _lists[tab]);
  }

  void _addKeyword(int tab) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('添加${_tabs[tab]}屏蔽词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入关键词'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              setState(() => _lists[tab].add(value.trim()));
              _save(tab);
            }
            Get.back();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                setState(() => _lists[tab].add(controller.text.trim()));
                _save(tab);
              }
              Get.back();
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('短视频屏蔽管理')),
      body: Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: _tabs.map((t) => Tab(text: t)).toList(),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: List.generate(3, (tab) {
                if (_lists[tab].isEmpty) {
                  return const Center(child: Text('暂无屏蔽词'));
                }
                return ListView.builder(
                  itemCount: _lists[tab].length,
                  itemBuilder: (context, i) => ListTile(
                    title: Text(_lists[tab][i]),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        setState(() => _lists[tab].removeAt(i));
                        _save(tab);
                      },
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () => _addKeyword(_tabController.index),
      ),
    );
  }
}
