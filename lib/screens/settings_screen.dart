import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/cloud_enhance.dart';
import '../services/photo_scanner.dart';
import '../services/log_service.dart';
import '../models/database_helper.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _photoCount = 0;
  bool _scanning = false;
  bool _cloudExpanded = false;
  bool _debugExpanded = false;
  bool _debugUnlocked = false;
  int _debugTapCount = 0;
  List<String> _allFolders = [];

  @override
  void initState() {
    super.initState();
    _loadStats();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _debugUnlocked = prefs.getBool('debug_unlocked') ?? false);
      }
    });
  }

  Future<void> _loadStats() async {
    final db = DatabaseHelper.instance;
    final photoCount = await db.getPhotoCount();
    final photos = await db.getAllPhotos();
    final folders = <String>{};
    for (final p in photos) {
      folders.add(p.path.substring(0, p.path.lastIndexOf('/')));
    }
    if (mounted) {
      setState(() {
        _photoCount = photoCount;
        _allFolders = folders.toList()..sort();
      });
    }
  }

  Future<void> _scanFromSettings() async {
    setState(() => _scanning = true);
    await context.read<PhotoScanner>().scanPhotos();
    await _loadStats();
    if (mounted) setState(() => _scanning = false);
  }

  void _showExcludedFoldersDialog(CloudEnhanceService cloud) {
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final excludedList =
              _allFolders.where((f) => cloud.isFolderExcluded(f)).toList();
          return AlertDialog(
            title: const Text('排除文件夹'),
            content: SizedBox(
              width: double.maxFinite,
              child: excludedList.isEmpty
                  ? const Text('暂无被排除的文件夹')
                  : ListView(
                      shrinkWrap: true,
                      children: excludedList.map((folder) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => _showFolderPathDialog(folder),
                                  child: Text(
                                    folder.split('/').last,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 32,
                                height: 32,
                                child: IconButton(
                                  icon: const Icon(Icons.settings_backup_restore,
                                      size: 19),
                                  tooltip: '恢复',
                                  padding: EdgeInsets.zero,
                                  onPressed: () async {
                                    await cloud.removeExcludedFolder(folder);
                                    setDialogState(() {});
                                  },
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showFolderPathDialog(String folderPath) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('文件夹路径'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(folderPath.split('/').last,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 16)),
            const SizedBox(height: 8),
            SelectableText(folderPath,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: folderPath));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('已复制到剪贴板'),
                        duration: Duration(seconds: 1)),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制路径'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  void _showTempShareDurationDialog(CloudEnhanceService cloud) {
    final controller = TextEditingController(text: '${cloud.tempShareDurationSec}');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('临时分享恢复时间'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('图片临时移动到分享文件夹后，多少秒自动恢复到原始位置。'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '秒数',
                suffixText: '秒',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [5, 10, 15, 30, 60].map((sec) {
                return ActionChip(
                  label: Text('$sec 秒'),
                  onPressed: () {
                    controller.text = '$sec';
                  },
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              if (v != null && v > 0 && v <= 300) {
                cloud.setTempShareDuration(v);
                setState(() {});
                Navigator.pop(context);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入 1～300 之间的整数')),
                );
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

    void _showPromptEditorDialog(CloudEnhanceService cloud) {
    final controller = TextEditingController(text: cloud.effectivePrompt);
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('编辑分析提示词'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '提示词用于指导 AI 如何分析图片。修改为空将恢复默认。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    minLines: 8,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '输入自定义提示词...',
                      isDense: true,
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '当前字数：${controller.text.length}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: () {
                          controller.text = cloud.defaultPrompt;
                          setDialogState(() {});
                        },
                        child: const Text('重置为默认'),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            onPressed: () async {
                              await cloud.setCustomPrompt(controller.text.trim());
                              if (mounted) {
                                setState(() {});
                                Navigator.pop(context);
                              }
                            },
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showClearLogsDialog(CloudEnhanceService cloud) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空调试日志'),
        content: const Text('确认清空所有调试日志？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await cloud.clearFailureLogs();
              if (mounted) {
                setState(() {});
                Navigator.pop(context);
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  void _showDebugLogsScreen(CloudEnhanceService cloud) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _DebugLogsScreen(cloud: cloud)),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _showAppLogsScreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _AppLogsScreen()),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cloudService = context.watch<CloudEnhanceService>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('相册扫描'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _scanning ? null : _scanFromSettings,
                icon: _scanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: Text(_scanning ? '扫描中...' : '扫描相册'),
              ),
            ),
          ),
          const _SectionHeader('数据统计'),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('已索引图片'),
            trailing: Text('$_photoCount 张'),
            onTap: () {
              if (_debugUnlocked) return;
              _debugTapCount++;
              if (_debugTapCount >= 5) {
                _debugUnlocked = true;
                SharedPreferences.getInstance()
                    .then((p) => p.setBool('debug_unlocked', true));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('调试模式已启用'),
                    duration: Duration(seconds: 1),
                  ),
                );
                setState(() {});
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.schedule_send),
            title: const Text('临时分享恢复时间'),
            subtitle: Text('${cloudService.tempShareDurationSec} 秒'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showTempShareDurationDialog(cloudService),
          ),
          InkWell(
            onTap: () => setState(() => _cloudExpanded = !_cloudExpanded),
            child: ListTile(
              leading: Icon(
                Icons.cloud,
                color: cloudService.isEnabled ? Colors.green : Colors.grey,
              ),
              title: const Text('云端解析'),
              subtitle: Text(cloudService.isEnabled
                  ? '已配置 ${cloudService.enabledModels.length} 个模型'
                  : '未配置模型'),
              trailing:
                  Icon(_cloudExpanded ? Icons.expand_less : Icons.expand_more),
            ),
          ),
          if (_cloudExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                children: [
                  const SizedBox(height: 4),
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('说明'),
                    subtitle: Text(
                        '填入 API 配置后，扫描时自动调用云端视觉大模型生成图片描述标签。\n最多配置 5 个模型，批量解析时自动分配并行处理。'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  ...List.generate(cloudService.models.length, (i) {
                    return _ModelConfigCard(
                      index: i,
                      model: cloudService.models[i],
                      canRemove: cloudService.models.length > 1,
                      onChanged: () => setState(() {}),
                      onRemove: () async {
                        await cloudService.removeModel(i);
                        setState(() {});
                      },
                    );
                  }),
                  if (cloudService.models.length < CloudEnhanceService.maxModels)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            cloudService.addModel();
                            setState(() {});
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(
                              '添加模型 (${cloudService.models.length}/${CloudEnhanceService.maxModels})'),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          if (_allFolders.isNotEmpty) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.folder_off),
              title: const Text('排除文件夹'),
              subtitle: Text(cloudService.excludedFolders.isEmpty
                  ? '未排除任何文件夹'
                  : '${cloudService.excludedFolders.length} 个文件夹被隐藏'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showExcludedFoldersDialog(cloudService),
            ),
          ],

          const Divider(),
          const _SectionHeader('隐私说明'),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '1. 本软件仅用于为本地图片生成 AI 标签，不收集、不上传任何用户数据。\n\n'
              '2. 云端标签功能依赖用户自行配置的第三方 API（如 OpenAI 等），图片传输仅发生在该 API 调用过程中，与本软件无关。\n\n'
              '3. 云端解析默认关闭，需用户主动开启。\n\n'
              '4. 所有标签和 OCR 文字仅存储在本地数据库，应用完全离线可用。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          if (_debugUnlocked) ...[
            const Divider(),
            const _SectionHeader('调试'),
            InkWell(
              onTap: () => setState(() => _debugExpanded = !_debugExpanded),
              child: ListTile(
                leading: const Icon(Icons.bug_report),
                title: const Text('调试选项'),
                subtitle: Text(cloudService.debugEnabled ? '已启用' : '已关闭'),
                trailing: Icon(
                    _debugExpanded ? Icons.expand_less : Icons.expand_more),
              ),
            ),
          ],
          if (_debugUnlocked && _debugExpanded) ...[
            SwitchListTile(
              secondary: const Icon(Icons.track_changes),
              title: const Text('启用调试日志'),
              subtitle: const Text('开启后记录云端解析详情（含成功/失败）'),
              value: cloudService.debugEnabled,
              onChanged: (v) {
                cloudService.setDebugEnabled(v);
                setState(() {});
              },
            ),
            Consumer<LogService>(
              builder: (_, logService, _) => SwitchListTile(
                secondary: const Icon(Icons.receipt_long),
                title: const Text('启用应用日志'),
                subtitle: const Text('记录应用运行日志到本地文件，包含所有模块'),
                value: logService.enabled,
                onChanged: (v) {
                  logService.setEnabled(v);
                  setState(() {});
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long),
              title: const Text('应用日志'),
              subtitle: Consumer<LogService>(
                builder: (_, logService, _) {
                  final total = logService.entries.length;
                  final errors = logService.entries
                      .where((e) => e.level == LogLevel.error).length;
                  return Text(total == 0
                      ? '暂无日志'
                      : '共 $total 条${errors > 0 ? '，错误 $errors 条' : ''}');
                },
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showAppLogsScreen(context),
            ),
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('编辑分析提示词'),
              subtitle: Text(cloudService.effectivePrompt.length > 60
                  ? '${cloudService.effectivePrompt.substring(0, 60)}...'
                  : cloudService.effectivePrompt),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showPromptEditorDialog(cloudService),
            ),
            ListTile(
              leading: const Icon(Icons.article),
              title: const Text('查看调试日志'),
              subtitle: Text(cloudService.failureLogs.isEmpty
                  ? '暂无日志'
                  : '共 ${cloudService.failureLogs.length} 条记录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: cloudService.failureLogs.isEmpty
                  ? null
                  : () => _showDebugLogsScreen(cloudService),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep, color: Colors.red),
              title: const Text('清空调试日志',
                  style: TextStyle(color: Colors.red)),
              trailing: const Icon(Icons.chevron_right),
              onTap: cloudService.failureLogs.isEmpty
                  ? null
                  : () => _showClearLogsDialog(cloudService),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单个模型配置卡片
class _ModelConfigCard extends StatefulWidget {
  final int index;
  final ModelConfig model;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _ModelConfigCard({
    required this.index,
    required this.model,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_ModelConfigCard> createState() => _ModelConfigCardState();
}

class _ModelConfigCardState extends State<_ModelConfigCard> {
  late TextEditingController _modelNameCtrl;
  late TextEditingController _baseUrlCtrl;
  late TextEditingController _apiKeyCtrl;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    _modelNameCtrl = TextEditingController(text: widget.model.modelName);
    _baseUrlCtrl = TextEditingController(text: widget.model.apiBaseUrl);
    _apiKeyCtrl = TextEditingController(text: widget.model.apiKey);
  }

  @override
  void didUpdateWidget(_ModelConfigCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model.modelName != widget.model.modelName &&
        _modelNameCtrl.text != widget.model.modelName) {
      _modelNameCtrl.text = widget.model.modelName;
    }
    if (oldWidget.model.apiBaseUrl != widget.model.apiBaseUrl &&
        _baseUrlCtrl.text != widget.model.apiBaseUrl) {
      _baseUrlCtrl.text = widget.model.apiBaseUrl;
    }
    if (oldWidget.model.apiKey != widget.model.apiKey &&
        _apiKeyCtrl.text != widget.model.apiKey) {
      _apiKeyCtrl.text = widget.model.apiKey;
    }
  }

  @override
  void dispose() {
    _modelNameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save(CloudEnhanceService cloud) async {
    await cloud.setModelName(widget.index, _modelNameCtrl.text);
    await cloud.setApiBaseUrl(widget.index, _baseUrlCtrl.text);
    await cloud.setApiKey(widget.index, _apiKeyCtrl.text);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cloud = context.read<CloudEnhanceService>();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: widget.model.isEnabled
                        ? Colors.green.shade50
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: widget.model.isEnabled
                          ? Colors.green.shade300
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.model.isEnabled
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 14,
                        color: widget.model.isEnabled
                            ? Colors.green
                            : Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '模型 ${widget.index + 1}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: widget.model.isEnabled
                              ? Colors.green.shade800
                              : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (widget.canRemove)
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '移除此模型',
                      padding: EdgeInsets.zero,
                      onPressed: widget.onRemove,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _modelNameCtrl,
              decoration: const InputDecoration(
                labelText: '模型名称',
                hintText: 'gpt-4o / claude-3-opus / gemini-2.0-flash',
                prefixIcon: Icon(Icons.model_training, size: 20),
                isDense: true,
              ),
              onChanged: (_) => _save(cloud),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _baseUrlCtrl,
              decoration: const InputDecoration(
                labelText: 'API Base URL',
                hintText: 'https://your-api.com/v1/chat/completions',
                prefixIcon: Icon(Icons.link, size: 20),
                isDense: true,
              ),
              onChanged: (_) => _save(cloud),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyCtrl,
              obscureText: !_showKey,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: 'sk-or-v1-...',
                prefixIcon: const Icon(Icons.key, size: 20),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    _showKey ? Icons.visibility_off : Icons.visibility,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
              onChanged: (_) => _save(cloud),
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugLogsScreen extends StatelessWidget {
  final CloudEnhanceService cloud;
  const _DebugLogsScreen({required this.cloud});

  static Future<void> _exportLogs(
      BuildContext context, CloudEnhanceService cloud) async {
    final buf = StringBuffer();
    buf.writeln('=== 随搜相册 调试日志 ===');
    buf.writeln('导出时间: ${DateTime.now().toString().substring(0, 19)}');
    buf.writeln('共 ${cloud.failureLogs.length} 条记录');
    buf.writeln('');

    for (int i = 0; i < cloud.failureLogs.length; i++) {
      final e = cloud.failureLogs[i];
      final time =
          '${e.timestamp.month.toString().padLeft(2, '0')}-${e.timestamp.day.toString().padLeft(2, '0')} '
          '${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}:${e.timestamp.second.toString().padLeft(2, '0')}';
      buf.writeln('--- [$i] ${e.isSuccess ? "成功" : "失败"} $time ---');
      buf.writeln('图片: ${e.imagePath}');
      buf.writeln('模型: ${e.modelName}');
      if (e.httpStatusCode != null) buf.writeln('HTTP: ${e.httpStatusCode}');
      if (e.errorMessage.isNotEmpty) buf.writeln('错误: ${e.errorMessage}');
      if (e.parsedTags != null && e.parsedTags!.isNotEmpty) {
        buf.writeln('标签: ${e.parsedTags}');
      }
      if (e.rawAIResponse != null && e.rawAIResponse!.isNotEmpty) {
        buf.writeln('AI 返回: ${e.rawAIResponse}');
      }
      if (e.responseBody != null && e.responseBody!.isNotEmpty) {
        buf.writeln('响应体: ${e.responseBody}');
      }
      buf.writeln('');
    }

    try {
      final dir = Directory.systemTemp;
      final file = File(
          '${dir.path}/debug_logs_${DateTime.now().millisecondsSinceEpoch}.txt');
      await file.writeAsString(buf.toString());
      await Share.shareXFiles([XFile(file.path)],
          text: '随搜相册调试日志');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('调试日志'),
        actions: [
          if (cloud.failureLogs.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '导出',
              onPressed: () => _exportLogs(context, cloud),
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清空',
              onPressed: () async {
                await cloud.clearFailureLogs();
                if (context.mounted) {
                  Navigator.pop(context);
                }
              },
            ),
          ],
        ],
      ),
      body: cloud.failureLogs.isEmpty
          ? const Center(
              child: Text('暂无日志', style: TextStyle(color: Colors.grey)),
            )
          : ListView.separated(
              itemCount: cloud.failureLogs.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = cloud.failureLogs[index];
                return _DebugLogEntryCard(entry: entry);
              },
            ),
    );
  }
}

class _DebugLogEntryCard extends StatelessWidget {
  final DebugLogEntry entry;
  const _DebugLogEntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final time =
        '${entry.timestamp.month.toString().padLeft(2, '0')}-${entry.timestamp.day.toString().padLeft(2, '0')} '
        '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: status + time
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: entry.isSuccess
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: entry.isSuccess ? Colors.green : Colors.red,
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    entry.isSuccess ? '成功' : '失败',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: entry.isSuccess ? Colors.green : Colors.red,
                    ),
                  ),
                ),
                const Spacer(),
                Text(time, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            // Info rows
            _infoRow('图片', entry.imagePath.split('/').last),
            _infoRow('路径', entry.imagePath),
            _infoRow('模型', entry.modelName),
            if (entry.httpStatusCode != null)
              _infoRow('HTTP 状态', '${entry.httpStatusCode}'),
            if (entry.errorMessage.isNotEmpty) ...[
              const SizedBox(height: 4),
              const Text('错误信息',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 2),
              SelectableText(
                entry.errorMessage,
                style: const TextStyle(fontSize: 13, color: Colors.red),
              ),
            ],
            if (entry.parsedTags != null && entry.parsedTags!.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('解析标签',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 2),
              SelectableText(entry.parsedTags!,
                  style: const TextStyle(fontSize: 13)),
            ],
            if (entry.rawAIResponse != null &&
                entry.rawAIResponse!.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('AI 原始返回',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 2),
              SelectableText(entry.rawAIResponse!,
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ],
            if (entry.responseBody != null &&
                entry.responseBody!.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('API 响应体',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 2),
              SelectableText(entry.responseBody!,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(label,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// 应用日志查看页面
class _AppLogsScreen extends StatefulWidget {
  const _AppLogsScreen();

  @override
  State<_AppLogsScreen> createState() => _AppLogsScreenState();
}

class _AppLogsScreenState extends State<_AppLogsScreen> {
  LogLevel? _filterLevel; // null = 全部
  String _keyword = '';
  final _keywordCtrl = TextEditingController();
  final Set<int> _expandedIndexes = {};

  List<LogEntry> get _filtered {
    final all = LogService.instance.entries;
    return all.where((e) {
      if (_filterLevel != null && e.level != _filterLevel) return false;
      if (_keyword.isNotEmpty) {
        final kw = _keyword.toLowerCase();
        if (!e.message.toLowerCase().contains(kw) &&
            !e.module.toLowerCase().contains(kw)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
    }
  }

  String _timeStr(LogEntry e) {
    final t = e.timestamp;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  void _shareLogs() async {
    try {
      await LogService.instance.shareLogs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败: $e')),
        );
      }
    }
  }

  void _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确认清空所有应用日志？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LogService.instance.clearAllLogs();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final all = LogService.instance.entries;
    final errors = all.where((e) => e.level == LogLevel.error).length;
    final warnings = all.where((e) => e.level == LogLevel.warning).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('应用日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: '导出分享',
            onPressed: all.isEmpty ? null : _shareLogs,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空',
            onPressed: all.isEmpty ? null : _clearLogs,
          ),
        ],
      ),
      body: Column(
        children: [
          // 筛选栏
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterChip(
                    label: const Text('全部', style: TextStyle(fontSize: 12)),
                    selected: _filterLevel == null,
                    onSelected: (_) => setState(() => _filterLevel = null),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  for (final level in LogLevel.values)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: FilterChip(
                        label: Text(level.label,
                            style: TextStyle(
                                fontSize: 12, color: _levelColor(level))),
                        selected: _filterLevel == level,
                        onSelected: (v) => setState(() =>
                            _filterLevel = v ? level : null),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 关键词搜索
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _keywordCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '搜索关键词...',
                hintStyle: const TextStyle(fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _keyword.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _keywordCtrl.clear();
                          setState(() => _keyword = '');
                        },
                      )
                    : null,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                filled: true,
              ),
              onChanged: (v) => setState(() => _keyword = v.trim()),
            ),
          ),
          // 日志列表
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text('暂无日志',
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      final isExpanded = _expandedIndexes.contains(index);
                      return InkWell(
                        onTap: entry.stackTrace != null
                            ? () => setState(() {
                                  if (isExpanded) {
                                    _expandedIndexes.remove(index);
                                  } else {
                                    _expandedIndexes.add(index);
                                  }
                                })
                            : null,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom:
                                  BorderSide(color: Colors.grey.shade200),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: _levelColor(entry.level)
                                          .withValues(alpha: 0.15),
                                      borderRadius:
                                          BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      entry.level.label,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: _levelColor(entry.level),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    entry.module,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    _timeStr(entry),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                entry.message,
                                style: const TextStyle(fontSize: 12),
                                maxLines: isExpanded ? null : 2,
                                overflow: isExpanded
                                    ? null
                                    : TextOverflow.ellipsis,
                              ),
                              if (isExpanded && entry.stackTrace != null) ...[
                                const SizedBox(height: 4),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius:
                                        BorderRadius.circular(4),
                                  ),
                                  child: SelectableText(
                                    entry.stackTrace!,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey.shade700,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                              if (entry.stackTrace != null && !isExpanded)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Icon(
                                    Icons.expand_more,
                                    size: 14,
                                    color: Colors.grey.shade400,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          // 底栏统计
          if (all.isNotEmpty)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: const Border(
                    top: BorderSide(color: Colors.grey, width: 0.3)),
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Text('共 ${all.length} 条',
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(width: 12),
                    if (errors > 0)
                      Text('错误 $errors',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.red)),
                    const SizedBox(width: 8),
                    if (warnings > 0)
                      Text('警告 $warnings',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.orange)),
                    const Spacer(),
                    if (_filterLevel != null || _keyword.isNotEmpty)
                      Text('显示 ${filtered.length}/${all.length}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.blue,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

