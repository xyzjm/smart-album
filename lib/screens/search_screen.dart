import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/photo.dart';
import '../models/database_helper.dart';
import '../services/cloud_enhance.dart';
import '../services/photo_scanner.dart';
import '../services/log_service.dart';
import '../widgets/photo_detail.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _db = DatabaseHelper.instance;

  List<Photo> _results = [];
  bool _searching = false;
  String _statusText = '';
  final List<String> _history = [];

  // 关联标签建议
  List<String> _relatedTags = [];
  String _lastSearchQuery = '';
  bool _relatedTagsExpanded = false;

  // 标签浏览
  Map<String, int> _allTags = {};
  bool _loadingTags = false;
  final _tagFilterCtrl = TextEditingController();
  static const int _tagPageSize = 100;

  List<MapEntry<String, int>> get _filteredTags {
    final filter = _tagFilterCtrl.text.trim().toLowerCase();
    final entries = _allTags.entries.where((e) {
      if (filter.isEmpty) return true;
      return e.key.toLowerCase().contains(filter);
    }).toList();
    if (filter.isEmpty && entries.length > _tagPageSize) {
      return entries.sublist(0, _tagPageSize);
    }
    return entries;
  }

  // 多选
  bool _selectMode = false;
  final Set<int> _selectedIds = {};

  // 临时分享
  static const _tempShareDir = '/storage/emulated/0/DCIM/Camera';
  final List<_TempShareEntry> _tempShareCopied = [];
  Timer? _tempShareTimer;
  DateTime? _tempShareStartedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadTags();
  }

  Future<void> _loadTags() async {
    setState(() => _loadingTags = true);
    try {
      final tags = await _db.getAllTags();
      if (mounted) setState(() { _allTags = tags; _loadingTags = false; });
    } catch (e) {
      if (mounted) setState(() => _loadingTags = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _tempShareTimer?.cancel();
      _tempShareTimer = null;
      _restoreTempSharedFiles();
    } else if (state == AppLifecycleState.resumed && _tempShareStartedAt != null) {
      final durSec = context.read<CloudEnhanceService>().tempShareDurationSec;
      if (DateTime.now().difference(_tempShareStartedAt!).inSeconds >= durSec) {
        _tempShareTimer?.cancel();
        _tempShareTimer = null;
        _restoreTempSharedFiles();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _focusNode.dispose();
    _tempShareTimer?.cancel();
    _tagFilterCtrl.dispose();
    _restoreTempSharedFiles(); // 退出时清理临时副本
    super.dispose();
  }

  /// 用标签替换搜索词中的匹配部分，保留其他关键词
  String _replaceInQuery(String query, String tag) {
    final searchWords = query
        .split(RegExp(r'[\s，,、。]+'))
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList();
    // 找到 tag 包含的搜索词，替换为 tag
    final newWords = searchWords.map((w) {
      return tag.contains(w) ? tag : w;
    }).toList();
    // 去重（多个搜索词可能被同一 tag 替换）
    final seen = <String>{};
    final deduped = newWords.where((w) => seen.add(w)).toList();
    return deduped.join('，');
  }

  /// 从搜索结果中提取与搜索词相关的标签建议
  List<String> _computeRelatedTags(String query, List<Photo> results) {
    // 解析搜索词
    final searchWords = query
        .split(RegExp(r'[\s，,、。]+'))
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList();
    if (searchWords.isEmpty || results.isEmpty) return [];

    // 收集所有标签及其出现次数
    final tagCounts = <String, int>{};
    for (final photo in results) {
      final tagsStr = photo.tags;
      if (tagsStr == null || tagsStr.isEmpty) continue;
      for (final raw in tagsStr.split(',')) {
        final tag = raw.trim();
        if (tag.isEmpty || tag.length >= 30) continue;
        tagCounts[tag] = (tagCounts[tag] ?? 0) + 1;
      }
    }

    // 筛选：标签包含任一搜索词，且不等于搜索词本身
    final related = tagCounts.entries
        .where((e) {
          final tag = e.key;
          // 排除完全等于某个搜索词的标签
          if (searchWords.any((w) => tag == w)) return false;
          // 标签必须包含至少一个搜索词
          return searchWords.any((w) => tag.contains(w));
        })
        .toList();

    // 按出现次数降序，次数相同按标签长度升序（短标签优先）
    related.sort((a, b) {
      final cmp = b.value.compareTo(a.value);
      if (cmp != 0) return cmp;
      return a.key.length.compareTo(b.key.length);
    });

    return related.map((e) => e.key).take(30).toList();
  }

  void _dismissKeyboard() {
    _focusNode.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  Future<void> _doSearch(String query) async {
    if (query.trim().isEmpty) return;
    _exitSelect();
    _dismissKeyboard();
    setState(() {
      _searching = true;
      _statusText = '搜索中...';
      _results = [];
    });

    try {
      final ids = await _db.searchByKeyword(query);
      final photos = await _db.getPhotosByIds(ids);

      // 计算关联标签建议
      final related = _computeRelatedTags(query, photos);

      if (mounted) {
        setState(() {
          _results = photos;
          _searching = false;
          _statusText = photos.isEmpty ? '未找到匹配的图片' : '';
          _relatedTags = related;
          _lastSearchQuery = query;

          if (!_history.contains(query)) {
            _history.insert(0, query);
            if (_history.length > 20) _history.removeLast();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _statusText = '搜索失败: $e';
        });
      }
    }
  }

  // --- 多选逻辑 ---

  void _toggleSelect(int id) {
    setState(() {
      _selectMode = true;
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelect() => setState(() { _selectMode = false; _selectedIds.clear(); });

  // --- 分享 ---

  void _shareSelected() {
    if (_selectedIds.isEmpty) return;
    final files = _results
        .where((p) => p.id != null && _selectedIds.contains(p.id))
        .map((p) => XFile(p.path))
        .toList();
    if (files.isNotEmpty) {
      Share.shareXFiles(files);
      _exitSelect();
    }
  }

  // --- 临时分享 ---

  Future<void> _tempShareSelected() async {
    if (_selectedIds.isEmpty) return;

    if (_tempShareTimer != null) {
      _tempShareTimer!.cancel();
      _tempShareTimer = null;
      await _restoreTempSharedFiles();
    }

    final sel = _results.where((p) => p.id != null && _selectedIds.contains(p.id)).toList();
    if (sel.isEmpty) return;

    final camDir = Directory(_tempShareDir);
    if (!await camDir.exists()) {
      await camDir.create(recursive: true);
    }

    int copied = 0;
    for (final photo in sel) {
      try {
        final src = File(photo.path);
        if (!await src.exists()) continue;

        final name = photo.path.split('/').last;
        String destPath = '$_tempShareDir/$name';
        int n = 1;
        while (await File(destPath).exists()) {
          final dot = name.lastIndexOf('.');
          final base = dot > 0 ? name.substring(0, dot) : name;
          final ext = dot > 0 ? name.substring(dot) : '';
          destPath = '$_tempShareDir/${base}_$n$ext';
          n++;
        }

        await File(destPath).writeAsBytes(await src.readAsBytes());
        if (!mounted) return;
        final uri = await context.read<PhotoScanner>().scanFile(destPath);
        _tempShareCopied.add(_TempShareEntry(destPath, uri));
        copied++;
      } catch (e) {
        LogService.instance.error('Search',
            'TempShare error for ${photo.id}: $e');
      }
    }

    if (!mounted) return;
    final durSec = context.read<CloudEnhanceService>().tempShareDurationSec;
    _exitSelect();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制 $copied 张图片到 Camera 文件夹，$durSec秒后自动删除'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    if (copied > 0) {
      _tempShareStartedAt = DateTime.now();
      _tempShareTimer = Timer(Duration(seconds: durSec), _restoreTempShared);
    }
  }

  Future<void> _restoreTempSharedFiles() async {
    if (_tempShareCopied.isEmpty) return;

    _tempShareStartedAt = null;
    final toDelete = List<_TempShareEntry>.from(_tempShareCopied);
    _tempShareCopied.clear();

    for (final entry in toDelete) {
      try {
        if (entry.uri != null) {
          await context.read<PhotoScanner>().deleteByUri(entry.uri!);
        } else {
          final f = File(entry.path);
          if (await f.exists()) {
            await f.delete();
            if (!mounted) return;
            context.read<PhotoScanner>().removeFromMediaStore(entry.path);
          }
        }
      } catch (e) {
        LogService.instance.error('Search',
            'Cleanup error for ${entry.path}: $e');
      }
    }
  }

  void _restoreTempShared() async {
    _tempShareTimer = null;
    await _restoreTempSharedFiles();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('临时分享的图片已自动删除'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  // --- 构建 ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelect,
              ),
              title: Text('已选 ${_selectedIds.length} 张'),
            )
          : AppBar(title: const Text('搜索图片')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              decoration: InputDecoration(
                hintText: '逗号/顿号/空格=且，句号=或。如"猫，橘。黑、蓝"',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          setState(() { _results = []; _statusText = ''; _relatedTags = []; _relatedTagsExpanded = false; });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                filled: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) => _doSearch(v),
              textInputAction: TextInputAction.search,
            ),
          ),
          if (_controller.text.isNotEmpty && !_searching)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _doSearch(_controller.text),
                  icon: const Icon(Icons.search),
                  label: const Text('搜索'),
                ),
              ),
            ),
          // 关联标签建议（可折叠）
          if (_relatedTags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => setState(() => _relatedTagsExpanded = !_relatedTagsExpanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            _relatedTagsExpanded ? Icons.expand_less : Icons.expand_more,
                            size: 20, color: Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text('相关标签（${_relatedTags.length}）点此${_relatedTagsExpanded ? "收起" : "展开"}',
                              style: TextStyle(fontSize: 13, color: Colors.grey[500])),
                        ],
                      ),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    alignment: Alignment.topCenter,
                    child: _relatedTagsExpanded
                        ? Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: SizedBox(
                              width: double.infinity,
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: _relatedTags.map((tag) => ActionChip(
                                  label: Text(tag, style: const TextStyle(fontSize: 12)),
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  onPressed: () {
                                    final newQuery = _replaceInQuery(_lastSearchQuery, tag);
                                    _controller.text = newQuery;
                                    _doSearch(newQuery);
                                  },
                                )).toList(),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 8),
                  Text('搜索中...'),
                ],
              ),
            ),
          if (_statusText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_statusText,
                  style: TextStyle(color: Colors.grey[600])),
            ),
          Expanded(
            child: _results.isEmpty && !_searching
                ? _buildIdleBody()
                : GridView.builder(
                    padding: const EdgeInsets.all(4),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final photo = _results[index];
                      final isSelected = photo.id != null && _selectedIds.contains(photo.id);
                      return RepaintBoundary(
                        child: GestureDetector(
                          onTap: () {
                            if (_selectMode && photo.id != null) {
                              _toggleSelect(photo.id!);
                            } else {
                              _showPhotoDetail(context, photo, _results);
                            }
                          },
                          onLongPress: () {
                            if (!_selectMode && photo.id != null) {
                              _toggleSelect(photo.id!);
                            }
                          },
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Hero(
                                tag: 'search_${photo.path}',
                                child: Image.file(
                                  File(photo.path),
                                  fit: BoxFit.cover,
                                  cacheWidth: 200,
                                  errorBuilder: (_, _, _) => const Center(
                                    child: Icon(Icons.broken_image, color: Colors.grey),
                                  ),
                                ),
                              ),
                              if (_selectMode)
                                Positioned.fill(
                                  child: Container(color: isSelected ? Colors.blue.withValues(alpha: 0.3) : Colors.transparent),
                                ),
                              if (_selectMode)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: isSelected
                                      ? const Icon(Icons.check_circle, color: Colors.blue, size: 24)
                                      : Icon(Icons.circle_outlined, color: Colors.white.withValues(alpha: 0.6), size: 24),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _selectMode ? _buildBottomBar() : null,
    );
  }

  Widget _buildIdleBody() {
    return CustomScrollView(
      slivers: [
        // 搜索历史
        if (_history.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _history
                    .take(10)
                    .map((h) => ActionChip(
                          label: Text(h, style: const TextStyle(fontSize: 13)),
                          onPressed: () {
                            _controller.text = h;
                            _doSearch(h);
                          },
                        ))
                    .toList(),
              ),
            ),
          ),
        // 标签云
        if (_loadingTags)
          const SliverFillRemaining(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_allTags.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题
                  Row(
                    children: [
                      Text('全部标签（${_allTags.length}）',
                          style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 标签筛选
                  SizedBox(
                    height: 36,
                    child: TextField(
                      controller: _tagFilterCtrl,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '筛选标签...',
                        hintStyle: const TextStyle(fontSize: 13),
                        prefixIcon: const Icon(Icons.filter_list, size: 18),
                        suffixIcon: _tagFilterCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _tagFilterCtrl.clear();
                                  setState(() {});
                                },
                              )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        filled: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 计数提示
                  if (_allTags.length > _tagPageSize && _tagFilterCtrl.text.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('显示前 $_tagPageSize 个高频标签，输入文字可筛选更多',
                          style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                    ),
                  _buildTagCloud(),
                ],
              ),
            ),
          )
        else
          const SliverFillRemaining(
            child: Center(
                child: Text('暂无标签，请先扫描图片并等待云端分析完成',
                    style: TextStyle(color: Colors.grey, fontSize: 15))),
          ),
      ],
    );
  }

  Widget _buildTagCloud() {
    final tags = _filteredTags;
    if (tags.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Center(
          child: Text(_tagFilterCtrl.text.isNotEmpty ? '无匹配标签' : '',
              style: const TextStyle(color: Colors.grey, fontSize: 14)),
        ),
      );
    }

    final maxCount = tags.first.value;
    final minCount = tags.last.value;
    final range = maxCount > minCount ? maxCount - minCount : 1;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tags.map((e) {
        final fontSize = 12.0 + (e.value - minCount) / range * 6.0;
        return ActionChip(
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(e.key,
                  style: TextStyle(fontSize: fontSize.clamp(12.0, 18.0))),
              const SizedBox(width: 2),
              Text('${e.value}',
                  style: TextStyle(
                      fontSize: (fontSize * 0.75).clamp(9.0, 12.0),
                      color: Colors.grey)),
            ],
          ),
          onPressed: () {
            _controller.text = e.key;
            _doSearch(e.key);
          },
        );
      }).toList(),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: const Border(top: BorderSide(color: Colors.grey, width: 0.3)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享',
              onPressed: _shareSelected,
            ),
            IconButton(
              icon: const Icon(Icons.schedule_send),
              tooltip: '临时分享',
              onPressed: _tempShareSelected,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: _deleteSelected,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('将删除选中的 $count 张图片，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    int deleted = 0;
    for (final photo in _results.toList()) {
      if (photo.id != null && _selectedIds.contains(photo.id)) {
        try {
          final file = File(photo.path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
        await _db.deletePhoto(photo.id!);
        _results.remove(photo);
        deleted++;
      }
    }
    _exitSelect();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除 $deleted 张图片')),
      );
    }
  }

  void _showPhotoDetail(BuildContext context, Photo photo, List<Photo> list) {
    _dismissKeyboard();
    final idx = list.indexWhere((p) => p.id == photo.id);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoDetailView(
          photos: list,
          initialIndex: idx >= 0 ? idx : 0,
          onDeleted: () {
            if (photo.id != null) {
              setState(() {
                _results.removeWhere((p) => p.id == photo.id);
              });
            }
          },
        ),
      ),
    ).then((_) => _dismissKeyboard());
  }
}

class _TempShareEntry {
  final String path;
  final String? uri;
  _TempShareEntry(this.path, this.uri);
}
