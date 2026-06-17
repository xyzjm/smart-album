import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';
import '../models/photo.dart';
import '../models/database_helper.dart';
import '../services/photo_scanner.dart';
import '../services/cloud_enhance.dart';
import '../services/log_service.dart';
import '../widgets/photo_detail.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final PhotoScanner _scanner;
  List<Photo> _photos = [];
  bool _loading = true;
  String? _errorMsg;
  String? _selectedFolder;
  DateTime? _lastBackPress;
  final ScrollController _folderScrollCtrl = ScrollController();
  final ScrollController _photoGridScrollCtrl = ScrollController();

  // 多选
  bool _selectMode = false;
  final Set<int> _selectedIds = {};
  List<Photo>? _cbPhotos;   // 剪贴板照片
  bool _cbIsCut = false;    // true=剪切, false=复制

  // 临时分享
  static const _tempShareDir = '/storage/emulated/0/DCIM/Camera';
  final List<_TempShareEntry> _tempShareCopied = [];
  Timer? _tempShareTimer;
  DateTime? _tempShareStartedAt;

  // 文件夹多选
  bool _folderSelectMode = false;
  final Set<String> _selectedFolders = {};

  // 文件夹分组缓存
  List<MapEntry<String, List<Photo>>> _folderEntries = const [];
  Map<String, List<Photo>> _folderMap = const {};
  int _analyzedCount = 0;

  // 日期分组缓存（选中文件夹后计算一次）
  List<MapEntry<DateTime, List<Photo>>> _dateGroups = const [];

  // 扁平网格缓存：将多个 SliverGrid 拍平为 Row 列表，大幅减少 sliver 数量
  List<_FlatGridItem> _flatGridItems = const [];
  double _lastGridWidth = 0;

  // 缩略图缓存：256px 压缩图，原图 10MB → 缩略图 20KB，加载快 500 倍
  String? _thumbnailCacheDir;
  final Map<String, String> _thumbnailMap = {}; // photoPath → thumbnailPath
  bool _thumbnailGenRunning = false;

  // 自定义滚动条
  bool _isDraggingThumb = false;
  bool _showThumb = false;
  String? _dragDateLabel;
  double _dragStartY = 0;
  double _dragStartScroll = 0;
  Timer? _thumbHideTimer;

  // 文件夹进出动画
  late final AnimationController _navController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _photoScale = CurvedAnimation(
    parent: _navController,
    curve: Curves.easeOut,
  );
  late final Animation<double> _photoFade = CurvedAnimation(
    parent: _navController,
    curve: const Interval(0, 0.5, curve: Curves.easeIn),
  );
  Alignment _tappedAlignment = Alignment.center;
  final Map<String, GlobalKey> _folderKeys = {};

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

  void _selectAll() {
    final allPhotos = _dateGroups.expand((g) => g.value).toList();
    setState(() {
      _selectMode = true;
      for (final p in allPhotos) {
        if (p.id != null) _selectedIds.add(p.id!);
      }
    });
  }

  void _toggleFolderSelect(String path) {
    setState(() {
      _folderSelectMode = true;
      if (_selectedFolders.contains(path)) {
        _selectedFolders.remove(path);
        if (_selectedFolders.isEmpty) _folderSelectMode = false;
      } else {
        _selectedFolders.add(path);
      }
    });
  }

  void _exitFolderSelect() => setState(() { _folderSelectMode = false; _selectedFolders.clear(); });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanner = context.read<PhotoScanner>();
    _initThumbnailCache();
    _loadPhotos();
    _scanner.state.addListener(_onScanStateChanged);
    _scanner.onProgress.addListener(_silentRefresh);
    _photoGridScrollCtrl.addListener(_onPhotoGridScrolled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _tempShareTimer?.cancel();
      _tempShareTimer = null;
      _restoreTempSharedFiles();
    } else if (state == AppLifecycleState.resumed && _tempShareStartedAt != null) {
      // 从后台回来时检查是否超时
      final durSec = context.read<CloudEnhanceService>().tempShareDurationSec;
      if (DateTime.now().difference(_tempShareStartedAt!).inSeconds >= durSec) {
        _tempShareTimer?.cancel();
        _tempShareTimer = null;
        _restoreTempSharedFiles();
      }
    }
  }

  void _onPhotoGridScrolled() {
    if (_isDraggingThumb) return;
    if (mounted) setState(() => _showThumb = true);
    _thumbHideTimer?.cancel();
    _thumbHideTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showThumb = false);
    });
  }

  List<Photo> _filterExcluded(List<Photo> photos) {
    final cloud = context.read<CloudEnhanceService>();
    return photos.where((p) {
      final dir = p.path.substring(0, p.path.lastIndexOf('/'));
      return !cloud.isFolderExcluded(dir);
    }).toList();
  }

  Future<void> _loadPhotos() async {
    final db = DatabaseHelper.instance;
    final photos = await db.getAllPhotos();
    if (mounted) {
      setState(() {
        _photos = _filterExcluded(photos);
        _loading = false;
        _updateCaches();
        if (_selectedFolder != null) {
          _dateGroups = _buildDateGroups(_selectedFolder!);
          _buildFlatGrid();
        }
      });
    }
  }

  /// 静默刷新（不影响 loading 状态），用于云端解析期间实时更新标签
  Timer? _silentRefreshTimer;
  Future<void> _silentRefresh() async {
    if (_silentRefreshTimer != null) return;
    _silentRefreshTimer = Timer(const Duration(milliseconds: 300), () async {
      _silentRefreshTimer = null;
      final photos = await DatabaseHelper.instance.getAllPhotos();
      if (mounted && _scanner.state.value == ScanState.scanning) {
        setState(() {
          _photos = _filterExcluded(photos);
          _updateCaches();
          if (_selectedFolder != null) {
            _dateGroups = _buildDateGroups(_selectedFolder!);
            _buildFlatGrid();
          }
        });
      }
    });
  }

  List<MapEntry<DateTime, List<Photo>>> _buildDateGroups(String folderPath) {
    final photos = _folderMap[folderPath] ?? [];
    final groups = <DateTime, List<Photo>>{};
    for (final p in photos) {
      final date = DateTime.fromMillisecondsSinceEpoch(p.timestamp);
      final day = DateTime(date.year, date.month, date.day);
      groups.putIfAbsent(day, () => []).add(p);
    }
    return groups.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
  }

  /// 将日期分组拍平为 (header / photo-row) 列表，消除多 SliverGrid 开销
  void _buildFlatGrid() {
    final items = <_FlatGridItem>[];
    for (final entry in _dateGroups) {
      items.add(_FlatGridItem(isHeader: true, date: entry.key));
      final photos = entry.value;
      for (int i = 0; i < photos.length; i += 3) {
        final end = (i + 3).clamp(0, photos.length);
        items.add(_FlatGridItem(isHeader: false, photos: photos.sublist(i, end), groupPhotos: photos));
      }
    }
    _flatGridItems = items;
  }

  void _updateCaches() {
    final map = <String, List<Photo>>{};
    int analyzed = 0;
    for (final photo in _photos) {
      final dir = photo.path.substring(0, photo.path.lastIndexOf('/'));
      map.putIfAbsent(dir, () => []).add(photo);
      if (photo.tags != null && photo.tags!.isNotEmpty) analyzed++;
    }
    _folderMap = map;
    _folderEntries = map.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    _analyzedCount = analyzed;
  }

  // ── 缩略图缓存 ──────────────────────────────────────────

  Future<void> _initThumbnailCache() async {
    final appDir = await getApplicationDocumentsDirectory();
    _thumbnailCacheDir = '${appDir.path}/thumbnails';
    await Directory(_thumbnailCacheDir!).create(recursive: true);
    // 加载已有缩略图映射
    _thumbnailMap.clear();
    try {
      final dir = Directory(_thumbnailCacheDir!);
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.jpg')) {
          // 文件名是 photoPath.hashCode 的 36 进制表示，无法反向映射
          // 改为延迟检测：显示时判断文件是否存在
        }
      }
    } catch (_) {}
  }

  String _thumbPath(String photoPath) {
    return '$_thumbnailCacheDir/${photoPath.hashCode.toRadixString(36)}.jpg';
  }

  /// 后台生成缩略图（一次最多 genCount 张），已有跳过
  Future<void> _genMissingThumbnails(List<Photo> photos, {int genCount = 50}) async {
    if (_thumbnailGenRunning || _thumbnailCacheDir == null) return;
    _thumbnailGenRunning = true;
    int done = 0;
    for (final photo in photos) {
      if (done >= genCount) break;
      final thumbPath = _thumbPath(photo.path);
      if (await File(thumbPath).exists()) {
        _thumbnailMap[photo.path] = thumbPath;
        continue;
      }
      try {
        final result = await FlutterImageCompress.compressWithFile(
          photo.path,
          minWidth: 256,
          minHeight: 256,
          quality: 70,
          format: CompressFormat.jpeg,
        );
        if (result != null) {
          await File(thumbPath).writeAsBytes(result);
          _thumbnailMap[photo.path] = thumbPath;
          done++;
        }
      } catch (e) {
        LogService.instance.debug('Gallery', 'Thumbnail gen failed: ${photo.path} $e');
      }
    }
    if (done > 0 && mounted) {
      setState(() {}); // 刷新可见缩略图
    }
    _thumbnailGenRunning = false;
  }

  void _onScanStateChanged() {
    final s = _scanner.state.value;
    if (s == ScanState.completed) {
      _loadPhotos();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('扫描完成'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else if (s == ScanState.error) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('扫描失败：请授予相册访问权限'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    final count = await _scanner.scanPhotos();
    if (mounted) {
      if (_scanner.state.value == ScanState.error) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请先授予相册访问权限，然后重试'),
            duration: Duration(seconds: 3),
          ),
        );
      } else if (count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('成功索引 $count 张新图片'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    await _loadPhotos();
  }

  void _showFolderMenu(String folderPath, List<Photo> folderPhotos) {
    final folderName = folderPath.split('/').last;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey, width: 0.3)),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(
                      File(folderPhotos.first.path),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      cacheWidth: 96,
                      errorBuilder: (_, _, _) => const Icon(Icons.folder, size: 48),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(folderName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        Text('${folderPhotos.length} 张图片', style: const TextStyle(fontSize: 13, color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload),
              title: const Text('云端解析此文件夹'),
              subtitle: const Text('将文件夹内所有图片发送到云端生成标签'),
              onTap: () {
                Navigator.pop(context);
                _cloudAnalyzeFolder(folderPath, folderPhotos);
              },
            ),
            Consumer<CloudEnhanceService>(
              builder: (_, cloud, _) {
                final excluded = cloud.isFolderExcluded(folderPath);
                return ListTile(
                  leading: Icon(excluded ? Icons.visibility : Icons.visibility_off),
                  title: Text(excluded ? '显示此文件夹' : '隐藏此文件夹'),
                  subtitle: Text(excluded ? '重新在主页面显示' : '不在主页显示，也不参与云端解析'),
                  onTap: () async {
                    Navigator.pop(context);
                    if (excluded) {
                      await cloud.removeExcludedFolder(folderPath);
                    } else {
                      await cloud.addExcludedFolder(folderPath);
                    }
                    await _loadPhotos();
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  bool _isParsed(Photo p) => p.tags != null && p.tags!.isNotEmpty;

  Future<void> _cloudAnalyzeSelectedFolders() async {
    final cloudService = context.read<CloudEnhanceService>();
    if (!cloudService.isEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置中启用云端解析并填入 API Key')),
        );
      }
      return;
    }
    final allPhotos = <Photo>[];
    for (final folder in _selectedFolders) {
      allPhotos.addAll(_folderMap[folder] ?? []);
    }
    final unparsed = allPhotos.where((p) => !_isParsed(p)).toList();
    final List<Photo> toAnalyze;
    if (unparsed.isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('重新解析'),
          content: Text('所选 ${_selectedFolders.length} 个文件夹均已解析，是否重新解析？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
          ],
        ),
      );
      if (confirmed != true) return;
      toAnalyze = allPhotos;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('云端解析'),
          content: Text('将通过第三方 API 为所选 ${_selectedFolders.length} 个文件夹（${unparsed.length} 张未解析）生成标签，是否继续？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始解析')),
          ],
        ),
      );
      if (confirmed != true) return;
      toAnalyze = unparsed;
    }
    _exitFolderSelect();
    final msg = await _scanner.cloudAnalyzePhotos(toAnalyze);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    await _loadPhotos();
  }

  Future<void> _hideSelectedFolders() async {
    final cloud = context.read<CloudEnhanceService>();
    final count = _selectedFolders.length;
    final allExcluded = _selectedFolders.every((f) => cloud.isFolderExcluded(f));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(allExcluded ? '显示文件夹' : '隐藏文件夹'),
        content: Text(allExcluded
            ? '将显示所选 $count 个文件夹'
            : '所选 $count 个文件夹将不在主页显示，也不上传解析'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final folder in _selectedFolders) {
      if (allExcluded) {
        await cloud.removeExcludedFolder(folder);
      } else {
        await cloud.addExcludedFolder(folder);
      }
    }
    _exitFolderSelect();
    await _loadPhotos();
  }

  Future<void> _cloudAnalyzeFolder(String folderPath, List<Photo> folderPhotos) async {
    final cloudService = context.read<CloudEnhanceService>();
    if (!cloudService.isEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置中启用云端解析并填入 API Key')),
        );
      }
      return;
    }
    final unparsed = folderPhotos.where((p) => !_isParsed(p)).toList();
    final List<Photo> toAnalyze;
    if (unparsed.isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('重新解析'),
          content: const Text('该文件夹图片均已解析过，是否重新解析？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
          ],
        ),
      );
      if (confirmed != true) return;
      toAnalyze = folderPhotos;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('云端解析'),
          content: Text('将通过第三方 API 为 ${unparsed.length} 张未解析的图片生成标签，是否继续？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始解析')),
          ],
        ),
      );
      if (confirmed != true) return;
      toAnalyze = unparsed;
    }
    final msg = await _scanner.cloudAnalyzePhotos(toAnalyze);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
    await _loadPhotos();
  }

  Future<void> _cloudAnalyzeSelected() async {
    final cloudService = context.read<CloudEnhanceService>();
    if (!cloudService.isEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置中启用云端解析并填入 API Key')),
        );
      }
      return;
    }
    final selected = _photos.where((p) => p.id != null && _selectedIds.contains(p.id)).toList();
    if (selected.isEmpty) return;
    final unparsed = selected.where((p) => !_isParsed(p)).toList();
    final List<Photo> toAnalyze;
    if (unparsed.isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('重新解析'),
          content: const Text('所选图片均已解析过，是否重新解析？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
          ],
        ),
      );
      if (confirmed != true) { _exitSelect(); return; }
      toAnalyze = selected;
    } else {
      toAnalyze = unparsed;
    }
    final msg = await _scanner.cloudAnalyzePhotos(toAnalyze);
    _exitSelect();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
    await _loadPhotos();
  }

  Future<void> _shareSelected() async {
    final selected = _photos.where((p) => p.id != null && _selectedIds.contains(p.id)).toList();
    if (selected.isEmpty) return;
    final files = selected.map((p) => XFile(p.path)).toList();
    await Share.shareXFiles(files, subject: '分享图片');
  }

  Future<void> _cloudAnalyze() async {
    final cloudService = context.read<CloudEnhanceService>();
    if (!cloudService.isEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置中启用云端增强并填入 API Key')),
        );
      }
      return;
    }

    final unparsed = _photos.where((p) => !_isParsed(p)).toList();
    if (unparsed.isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('重新解析'),
          content: const Text('全部图片均已解析过，是否重新解析？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
          ],
        ),
      );
      if (confirmed != true) return;
      final msg = await _scanner.cloudAnalyzeAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
      await _loadPhotos();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('云端解析'),
        content: Text('${unparsed.length} 张图片未解析，将通过第三方 API 生成标签，是否继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始解析')),
        ],
      ),
    );
    if (confirmed != true) return;

    final msg = await _scanner.cloudAnalyzePhotos(unparsed);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
    await _loadPhotos();
  }

  void _onFolderSelected(String folderPath) {
    // 获取被点击文件夹在屏幕上的位置，用于缩放动画原点
    final key = _folderKeys[folderPath];
    if (key?.currentContext != null) {
      final box = key!.currentContext!.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final offset = box.localToGlobal(Offset.zero, ancestor: context.findRenderObject());
        final size = context.size!;
        _tappedAlignment = Alignment(
          (offset.dx + box.size.width / 2) / (size.width / 2) - 1,
          (offset.dy + box.size.height / 2) / (size.height / 2) - 1,
        );
      }
    }
    // 预计算：setState 前完成数据计算，避免动画帧内做重活
    _dateGroups = _buildDateGroups(folderPath);
    _buildFlatGrid();
    // 后台生成缩略图（不阻塞 UI）
    _genMissingThumbnails(_dateGroups.expand((g) => g.value).toList());
    if (mounted) {
      setState(() {
        _selectedFolder = folderPath;
      });
      _navController.forward();
    }
  }

  void _goBackToFolders() {
    _navController.reverse().then((_) {
      if (mounted) {
        setState(() { _selectedFolder = null; _dateGroups = const []; });
      }
    });
  }

  void _showQuickTagDialog() {
    if (_selectedFolder == null) return;
    final photos = _dateGroups.expand((g) => g.value).toList();
    if (photos.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _QuickTagScreen(
        photos: photos,
        db: DatabaseHelper.instance,
        folderPath: _selectedFolder!,
      )),
    ).then((_) => _loadPhotos());
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectMode) {
          _exitSelect();
          return;
        }
        if (_folderSelectMode) {
          _exitFolderSelect();
          return;
        }
        if (_selectedFolder != null) {
          _goBackToFolders();
          return;
        }
        // 主页：再按一次退出（扫描中则退到后台）
        final now = DateTime.now();
        if (_lastBackPress != null &&
            now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
          if (_scanner.state.value == ScanState.scanning) {
            _scanner.moveToBackground();
          } else {
            SystemNavigator.pop();
          }
        } else {
          _lastBackPress = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('再按一次退出应用'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
      child: Scaffold(
      appBar: AppBar(
        leading: _selectMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelect,
              )
            : _folderSelectMode
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _exitFolderSelect,
                  )
                : _selectedFolder != null
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _goBackToFolders,
                      )
                    : null,
        title: _selectMode
            ? Text('已选 ${_selectedIds.length} 张')
            : _folderSelectMode
                ? Text('已选 ${_selectedFolders.length} 个文件夹')
                : Text(_selectedFolder != null
                    ? _selectedFolder!.split('/').last
                    : '随搜相册'),
        actions: [
          if (_folderSelectMode) ...[
            IconButton(
              icon: const Icon(Icons.cloud_upload),
              tooltip: '解析所选文件夹',
              onPressed: _cloudAnalyzeSelectedFolders,
            ),
            IconButton(
              icon: const Icon(Icons.visibility_off),
              tooltip: '隐藏/显示所选',
              onPressed: _hideSelectedFolders,
            ),
          ] else if (_selectMode) ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: '全选',
              onPressed: _selectAll,
            ),
          ] else if (_cbPhotos != null && _selectedFolder != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Chip(
                label: Text('${_cbIsCut ? "剪切" : "复制"} ${_cbPhotos!.length} 张'),
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () => setState(() { _cbPhotos = null; }),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.content_paste),
              tooltip: '粘贴到此处',
              onPressed: _pasteToFolder,
            ),
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: '在文件管理器中打开',
              onPressed: () => _scanner.openFolder(_selectedFolder!),
            ),
            IconButton(
              icon: const Icon(Icons.local_offer),
              tooltip: '快速打标签',
              onPressed: _showQuickTagDialog,
            ),
          ] else if (_selectedFolder != null) ...[
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: '在文件管理器中打开',
              onPressed: () => _scanner.openFolder(_selectedFolder!),
            ),
            IconButton(
              icon: const Icon(Icons.local_offer),
              tooltip: '快速打标签',
              onPressed: _showQuickTagDialog,
            ),
          ] else if (_selectedFolder == null) ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: '搜索',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SearchScreen()),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.cloud_upload),
              tooltip: '全部云端解析',
              onPressed: _loading ? null : _cloudAnalyze,
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: '设置',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ).then((_) => _loadPhotos()),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          ValueListenableBuilder<ScanProgress?>(
            valueListenable: _scanner.onProgress,
            builder: (context, progress, _) {
              final isScanning = _scanner.state.value == ScanState.scanning || _loading;
              if (!isScanning || progress == null) return const SizedBox.shrink();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: progress.total > 0 ? progress.current / progress.total : null),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        Text('${progress.current}/${progress.total}', style: const TextStyle(fontSize: 12)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            progress.currentPath.split('/').last,
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: () { _scanner.cancel(); setState(() => _loading = false); },
                          child: const Text('停止', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: _navController,
              child: _buildPhotoGrid(),
              builder: (context, photoGrid) {
                final showingDetail = _selectedFolder != null;
                return Stack(
                  children: [
                    _buildFolderGrid(),
                    if (showingDetail || _navController.isAnimating)
                      FadeTransition(
                        opacity: _photoFade,
                        child: ScaleTransition(
                          scale: _photoScale,
                          alignment: _tappedAlignment,
                          child: Container(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            child: photoGrid,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: _selectMode ? _buildSelectBottomBar() : null,
      ), // PopScope
    );
  }

  Widget _buildSelectBottomBar() {
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
              icon: const Icon(Icons.copy),
              tooltip: '复制',
              onPressed: _copySelected,
            ),
            IconButton(
              icon: const Icon(Icons.content_cut),
              tooltip: '剪切',
              onPressed: _cutSelected,
            ),
            IconButton(
              icon: const Icon(Icons.schedule_send),
              tooltip: '临时分享',
              onPressed: _tempShareSelected,
            ),
            IconButton(
              icon: const Icon(Icons.cloud_upload),
              tooltip: '解析所选',
              onPressed: _cloudAnalyzeSelected,
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

  /// 文件夹网格视图
  Widget _buildFolderGrid() {
    if (_loading && _photos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_photos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined,
                size: 80, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('暂未发现图片', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text('请前往「设置」→「扫描相册」开始索引',
                style: TextStyle(color: Colors.grey)),
            if (_errorMsg != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_errorMsg!,
                    style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loading ? null : _startScan,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(_loading ? '扫描中...' : '开始扫描相册'),
            ),
          ],
        ),
      );
    }

    final totalCount = _photos.length;

    return RefreshIndicator(
        onRefresh: _loadPhotos,
        child: CustomScrollView(
          controller: _folderScrollCtrl,
          slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                  '${_folderEntries.length} 个文件夹 · 共 $totalCount 张 · 已解析 $_analyzedCount 张',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
                childAspectRatio: 0.85,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final entry = _folderEntries[index];
                  final photos = entry.value;
                  final analyzed = photos.where((p) => p.tags != null && p.tags!.isNotEmpty).length;
                  final folderKey = _folderKeys.putIfAbsent(entry.key, () => GlobalKey());
                  return _FolderTile(
                    key: folderKey,
                    folderPath: entry.key,
                    photoCount: photos.length,
                    analyzedCount: analyzed,
                    coverPath: photos.first.path,
                    onTap: () {
                      if (_folderSelectMode) {
                        _toggleFolderSelect(entry.key);
                      } else {
                        _onFolderSelected(entry.key);
                      }
                    },
                    onLongPress: () {
                      if (!_folderSelectMode) {
                        _toggleFolderSelect(entry.key);
                      }
                    },
                    selectMode: _folderSelectMode,
                    isSelected: _selectedFolders.contains(entry.key),
                  );
                },
                childCount: _folderEntries.length,
              ),
            ),
          ),
          ],
      ),
    );
  }

  /// 文件夹内图片网格（拍平为单个 SliverList，消除多 SliverGrid 导致的动画卡顿）
  Widget _buildPhotoGrid() {
    if (_selectedFolder == null || _flatGridItems.isEmpty) return const SizedBox.shrink();

    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);
    final yesterday = todayDay.subtract(const Duration(days: 1));

    return LayoutBuilder(
      builder: (context, constraints) {
        final gridWidth = constraints.maxWidth;
        if (gridWidth != _lastGridWidth) {
          _lastGridWidth = gridWidth;
          _precomputeDateOffsetsForWidth(gridWidth);
        }
        return Stack(
          children: [
            RefreshIndicator(
              onRefresh: _loadPhotos,
              child: CustomScrollView(
                controller: _photoGridScrollCtrl,
                cacheExtent: 800,
                slivers: [
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = _flatGridItems[index];
                        if (item.isHeader) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
                            child: Text(
                              _dateLabel(item.date!, todayDay, yesterday),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          );
                        }
                        // 照片行：每行 1~3 张
                        final rowPhotos = item.photos!;
                        final itemSize = (gridWidth - 3 * 2 - 4 * 2) / 3; // spacing + padding
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
                          child: Row(
                            children: [
                              for (int i = 0; i < 3; i++)
                                i < rowPhotos.length
                                    ? SizedBox(
                                        width: itemSize,
                                        height: itemSize,
                                        child: _PhotoThumbnail(
                                          photo: rowPhotos[i],
                                          selectMode: _selectMode,
                                          isSelected: rowPhotos[i].id != null &&
                                              _selectedIds.contains(rowPhotos[i].id),
                                          thumbnailPath: _thumbnailMap[rowPhotos[i].path],
                                          onTap: () {
                                            if (_selectMode) {
                                              _toggleSelect(rowPhotos[i].id!);
                                            } else {
                                              _showPhotoDetail(rowPhotos[i], item.groupPhotos!);
                                            }
                                          },
                                          onLongPress: () {
                                            if (!_selectMode && rowPhotos[i].id != null) {
                                              _toggleSelect(rowPhotos[i].id!);
                                            }
                                          },
                                        ),
                                      )
                                    : SizedBox(width: itemSize, height: itemSize), // 占位保持对齐
                              if (rowPhotos.length < 3) const Spacer(),
                            ],
                          ),
                        );
                      },
                      childCount: _flatGridItems.length,
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: true,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 2,
              top: 0,
              bottom: 0,
              child: _buildDragThumb(todayDay, yesterday),
            ),
          ],
        );
      },
    );
  }

  List<(double, DateTime)> _datePositions = []; // (offset, date) — 拖拽滚动条日期标签映射

  void _precomputeDateOffsetsForWidth(double gridWidth) {
    _datePositions = [];
    double offset = 0;
    const headerH = 38.0;
    const rowGap = 3.0;
    final itemSize = (gridWidth - 3 * 2 - 4 * 2) / 3;
    for (final item in _flatGridItems) {
      if (item.isHeader) {
        _datePositions.add((offset, item.date!));
        offset += headerH;
      } else {
        offset += itemSize + rowGap;
      }
    }
  }

  Widget _buildDragThumb(DateTime todayDay, DateTime yesterday) {
    final maxScroll = _photoGridScrollCtrl.hasClients
        ? _photoGridScrollCtrl.position.maxScrollExtent
        : 0.0;
    final scrollPixels = _photoGridScrollCtrl.hasClients
        ? _photoGridScrollCtrl.position.pixels
        : 0.0;

    return SizedBox(
      width: 28,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackHeight = constraints.maxHeight;
          const thumbHeight = 64.0;
          final availableH = trackHeight - thumbHeight;
          final thumbTop = maxScroll > 0
              ? (scrollPixels / maxScroll * availableH).clamp(0.0, availableH)
              : 0.0;
          final ratio = availableH > 0 ? maxScroll / availableH : 0.0;

          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (details) {
              _dragStartY = details.globalPosition.dy;
              _dragStartScroll = scrollPixels;
              setState(() {
                _isDraggingThumb = true;
                _showThumb = true;
                _thumbHideTimer?.cancel();
                _dragDateLabel = _dateAtScroll(scrollPixels, todayDay, yesterday);
              });
            },
            onVerticalDragUpdate: (details) {
              if (maxScroll <= 0) return;
              final totalDrag = details.globalPosition.dy - _dragStartY;
              final newScroll =
                  (_dragStartScroll + totalDrag * ratio).clamp(0.0, maxScroll);
              _photoGridScrollCtrl.jumpTo(newScroll);
              setState(() {
                _dragDateLabel = _dateAtScroll(newScroll, todayDay, yesterday);
              });
            },
            onVerticalDragEnd: (_) {
              setState(() {
                _isDraggingThumb = false;
                _dragDateLabel = null;
              });
              _thumbHideTimer = Timer(const Duration(milliseconds: 800), () {
                if (mounted) setState(() => _showThumb = false);
              });
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (_showThumb || _isDraggingThumb)
                  Positioned(
                    top: thumbTop,
                    right: 0,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: 26,
                      height: thumbHeight,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.keyboard_arrow_up, size: 18,
                              color: Theme.of(context).colorScheme.primary),
                          Icon(Icons.keyboard_arrow_down, size: 18,
                              color: Theme.of(context).colorScheme.primary),
                        ],
                      ),
                    ),
                  ),
                if (_isDraggingThumb && _dragDateLabel != null)
                  Positioned(
                    top: (thumbTop + thumbHeight / 2 - 16).clamp(-16.0, trackHeight - 48),
                    right: 32,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 4,
                            offset: const Offset(2, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        _dragDateLabel!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _dateAtScroll(double scrollOffset, DateTime todayDay, DateTime yesterday) {
    if (_datePositions.isEmpty) return '';
    for (int i = _datePositions.length - 1; i >= 0; i--) {
      if (scrollOffset >= _datePositions[i].$1 - 4) {
        return _dateLabel(_datePositions[i].$2, todayDay, yesterday);
      }
    }
    return _dateLabel(_datePositions.first.$2, todayDay, yesterday);
  }

  String _dateLabel(DateTime day, DateTime today, DateTime yesterday) {
    if (day == today) return '今天';
    if (day == yesterday) return '昨天';
    final now = DateTime.now();
    if (day.year == now.year) return '${day.month}月${day.day}日';
    return '${day.year}年${day.month}月${day.day}日';
  }

  void _showPhotoDetail(Photo photo, List<Photo> list) {
    final idx = list.indexWhere((p) => p.id == photo.id);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoDetailView(
          photos: list,
          initialIndex: idx >= 0 ? idx : 0,
          onDeleted: _loadPhotos,
        ),
      ),
    ).then((_) => _loadPhotos());
  }

  void _copySelected() {
    if (_selectedIds.isEmpty) return;
    _cbPhotos = _photos.where((p) => p.id != null && _selectedIds.contains(p.id)).toList();
    _cbIsCut = false;
    _exitSelect();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${_cbPhotos!.length} 张图片，进入文件夹后粘贴')),
    );
  }

  void _cutSelected() {
    if (_selectedIds.isEmpty) return;
    _cbPhotos = _photos.where((p) => p.id != null && _selectedIds.contains(p.id)).toList();
    _cbIsCut = true;
    _exitSelect();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已剪切 ${_cbPhotos!.length} 张图片，进入文件夹后粘贴')),
    );
  }

  Future<bool> _ensureStoragePerm() async {
    if (await Permission.manageExternalStorage.isGranted) return true;
    final result = await Permission.manageExternalStorage.request();
    return result.isGranted;
  }

  Future<void> _pasteToFolder() async {
    if (_cbPhotos == null || _cbPhotos!.isEmpty || _selectedFolder == null) return;
    if (!await _ensureStoragePerm()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要「管理所有文件」权限才能操作文件')),
        );
      }
      return;
    }
    final db = DatabaseHelper.instance;
    final photos = _cbPhotos!;
    final isCut = _cbIsCut;
    int success = 0;
    for (final photo in photos) {
      try {
        final src = File(photo.path);
        if (!await src.exists()) {
          await db.deletePhoto(photo.id!);
          continue;
        }
        final name = photo.path.split('/').last;
        String destPath = '$_selectedFolder/$name';
        int n = 1;
        while (await File(destPath).exists()) {
          final dot = name.lastIndexOf('.');
          final base = dot > 0 ? name.substring(0, dot) : name;
          final ext = dot > 0 ? name.substring(dot) : '';
          destPath = '$_selectedFolder/${base}_$n$ext';
          n++;
        }
        if (isCut) {
          try {
            await src.rename(destPath);
          } catch (_) {
            // rename 失败则用字节复制再删原文件
            await File(destPath).writeAsBytes(await src.readAsBytes());
            await src.delete();
          }
          await db.updatePhoto(photo.copyWith(path: destPath));
        } else {
          await File(destPath).writeAsBytes(await src.readAsBytes());
          // 为复制的新文件创建新记录
          final stat = await File(destPath).stat();
          final newPhoto = Photo(
            path: destPath,
            timestamp: stat.modified.millisecondsSinceEpoch,
            width: photo.width,
            height: photo.height,
            hash: '${stat.size}_${stat.modified.millisecondsSinceEpoch}',
            tags: photo.tags,
            ocrText: photo.ocrText,
            cloudData: photo.cloudData,
          );
          await db.insertPhoto(newPhoto);
        }
        success++;
      } catch (e) {
        LogService.instance.error('Gallery', 'Paste error: $e');
      }
    }
    final total = photos.length;
    _cbPhotos = null;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已${isCut ? "移动" : "复制"} $success/$total 张图片')),
      );
      await _loadPhotos();
    }
  }

  Future<void> _tempShareSelected() async {
    if (_selectedIds.isEmpty) return;

    // 如果已有进行中的临时分享，先清理
    if (_tempShareTimer != null) {
      _tempShareTimer!.cancel();
      _tempShareTimer = null;
      await _restoreTempSharedFiles();
    }

    final sel = _photos.where((p) => p.id != null && _selectedIds.contains(p.id)).toList();
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
        final uri = await _scanner.scanFile(destPath);
        _tempShareCopied.add(_TempShareEntry(destPath, uri));
        copied++;
      } catch (e) {
        LogService.instance.error('Gallery',
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
        // 优先通过 MediaStore URI 删除（同时清除媒体记录 + 文件）
        if (entry.uri != null) {
          await _scanner.deleteByUri(entry.uri!);
        } else {
          // 降级：直接删文件 + 清除媒体记录
          final f = File(entry.path);
          if (await f.exists()) {
            await f.delete();
            _scanner.removeFromMediaStore(entry.path);
          }
        }
      } catch (e) {
        LogService.instance.error('Gallery',
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

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    if (!await _ensureStoragePerm()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要「管理所有文件」权限才能删除文件')),
        );
      }
      return;
    }
    final count = _selectedIds.length;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('将删除 $count 张图片，此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;

    final db = DatabaseHelper.instance;
    int deleted = 0;
    for (final id in _selectedIds.toList()) {
      final photo = await db.getPhotoById(id);
      if (photo == null) continue;
      try {
        final file = File(photo.path);
        if (await file.exists()) await file.delete();
        await db.deletePhoto(id);
        deleted++;
      } catch (e) {
        LogService.instance.error('Gallery', 'Delete error for $id: $e');
      }
    }
    _exitSelect();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除 $deleted 张图片')),
      );
      await _loadPhotos();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _silentRefreshTimer?.cancel();
    _thumbHideTimer?.cancel();
    _tempShareTimer?.cancel();
    _restoreTempSharedFiles(); // 退出时清理临时副本
    _folderScrollCtrl.dispose();
    _photoGridScrollCtrl.dispose();
    _scanner.state.removeListener(_onScanStateChanged);
    _scanner.onProgress.removeListener(_silentRefresh);
    _navController.dispose();
    super.dispose();
  }
}

/// 文件夹缩略图卡片
class _TempShareEntry {
  final String path;
  final String? uri;
  _TempShareEntry(this.path, this.uri);
}

class _FolderTile extends StatelessWidget {
  final String folderPath;
  final int photoCount;
  final int analyzedCount;
  final String coverPath;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectMode;
  final bool isSelected;

  const _FolderTile({
    super.key,
    required this.folderPath,
    required this.photoCount,
    required this.analyzedCount,
    required this.coverPath,
    required this.onTap,
    this.onLongPress,
    this.selectMode = false,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final folderName = folderPath.split('/').last;
    final allAnalyzed = analyzedCount == photoCount;

    return RepaintBoundary(
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Card(
          clipBehavior: Clip.antiAlias,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(coverPath),
                fit: BoxFit.cover,
                cacheWidth: 256,
                filterQuality: FilterQuality.low,
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(Icons.folder, size: 40, color: Colors.grey),
                ),
              ),
              if (selectMode)
                Positioned.fill(
                  child: Container(
                    color: isSelected ? Colors.blue.withValues(alpha: 0.3) : Colors.black26,
                  ),
                ),
              if (selectMode)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected ? Colors.blue : Colors.white.withValues(alpha: 0.7),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : null,
                  ),
                ),
              if (!selectMode && allAnalyzed)
                const Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(Icons.cloud_done, color: Colors.greenAccent, size: 16),
                ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 20, 8, 6),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        folderName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '$photoCount 张${allAnalyzed ? "" : " · $analyzedCount 已解析"}',
                        style: TextStyle(
                          color: allAnalyzed ? Colors.greenAccent : Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 快速打标签页：输入标签文本，点击图片即刻写入
class _QuickTagScreen extends StatefulWidget {
  final List<Photo> photos;
  final DatabaseHelper db;
  final String folderPath;

  const _QuickTagScreen({
    required this.photos,
    required this.db,
    required this.folderPath,
  });

  @override
  State<_QuickTagScreen> createState() => _QuickTagScreenState();
}

class _QuickTagScreenState extends State<_QuickTagScreen> {
  final _tagCtrl = TextEditingController();
  final _selectedIds = <int>{};

  @override
  void dispose() {
    _tagCtrl.dispose();
    super.dispose();
  }

  void _toggleSelect(Photo photo) {
    if (_tagCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入标签文字'), duration: Duration(seconds: 1)),
      );
      return;
    }
    setState(() {
      if (_selectedIds.contains(photo.id)) {
        _selectedIds.remove(photo.id);
      } else {
        _selectedIds.add(photo.id!);
      }
    });
  }

  Future<void> _confirm() async {
    if (_selectedIds.isEmpty) return;
    final tag = _tagCtrl.text.trim();
    if (tag.isEmpty) return;

    final count = _selectedIds.length;
    for (final id in _selectedIds) {
      final photo = widget.photos.firstWhere((p) => p.id == id);
      final existing = photo.tags ?? '';
      final allTags = [
        if (existing.isNotEmpty) existing,
        tag,
      ].where((s) => s.isNotEmpty).join(', ');
      await widget.db.updatePhoto(photo.copyWith(tags: allTags));
    }

    setState(() {
      _selectedIds.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已为 $count 张图片打上标签「$tag」'), duration: const Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final folderName = widget.folderPath.split('/').last;
    return Scaffold(
      appBar: AppBar(
        title: Text('快速打标签 - $folderName'),
        actions: [
          TextButton(
            onPressed: _selectedIds.isEmpty ? null : _confirm,
            child: const Text('确定'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _tagCtrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '输入标签，如：猫、风景、美食',
                labelText: '标签文字',
                prefixIcon: const Icon(Icons.local_offer),
                suffixIcon: _tagCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _tagCtrl.clear(),
                      )
                    : null,
                border: const OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text('点击图片选中，再点取消，按确定写入',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
                const Spacer(),
                Text('${_selectedIds.length} 张', style: const TextStyle(fontSize: 13, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 3,
                mainAxisSpacing: 3,
                childAspectRatio: 1.0,
              ),
              itemCount: widget.photos.length,
              itemBuilder: (context, index) {
                final photo = widget.photos[index];
                final isSelected = _selectedIds.contains(photo.id);
                return GestureDetector(
                  onTap: () => _toggleSelect(photo),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(photo.path),
                        fit: BoxFit.cover,
                        cacheWidth: 200,
                        cacheHeight: 200,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                      ),
                      if (isSelected)
                        Positioned.fill(
                          child: Container(color: Colors.blue.withValues(alpha: 0.25)),
                        ),
                      if (isSelected)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.blue,
                            ),
                            child: const Icon(Icons.check, size: 16, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
/// 图片缩略图（优先显示压缩缓存，降级用原图 + 低质量缩放）
class _PhotoThumbnail extends StatelessWidget {
  final Photo photo;
  final bool selectMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String? thumbnailPath;

  const _PhotoThumbnail({
    required this.photo,
    this.selectMode = false,
    this.isSelected = false,
    required this.onTap,
    required this.onLongPress,
    this.thumbnailPath,
  });

  bool get _hasTags => photo.tags != null && photo.tags!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // 优先使用预生成的 256px 压缩缩略图（20KB），否则用原图解码
    final useThumb = thumbnailPath != null && File(thumbnailPath!).existsSync();
    return RepaintBoundary(
      child: GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Hero(
        tag: 'img_${photo.path}',
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(useThumb ? thumbnailPath! : photo.path),
              fit: BoxFit.cover,
              cacheWidth: useThumb ? null : 200,
              cacheHeight: useThumb ? null : 200,
              filterQuality: useThumb ? FilterQuality.none : FilterQuality.low,
              errorBuilder: (_, _, _) => const Center(
                  child: Icon(Icons.broken_image, size: 24, color: Colors.grey)),
            ),
          // 选择模式覆盖层
          if (selectMode)
            Positioned.fill(
              child: Container(
                color: isSelected ? Colors.blue.withValues(alpha: 0.3) : Colors.transparent,
              ),
            ),
          if (selectMode)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? Colors.blue : Colors.white.withValues(alpha: 0.7),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: isSelected
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            ),
          if (!selectMode && _hasTags)
            Positioned(
              bottom: 2,
              right: 2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.all(Radius.circular(3)),
                ),
                child: const Icon(Icons.cloud_done, color: Colors.greenAccent, size: 14),
              ),
            ),
        ],
        ),
      ),
      ),
    );
  }
}

/// 扁平网格项：将日期分组的 SliverGrid 拍平为 header/row 序列
class _FlatGridItem {
  final bool isHeader;
  final DateTime? date;
  final List<Photo>? photos;     // 当前行（1~3张）
  final List<Photo>? groupPhotos; // 所属日期分组的全部照片（仅 photo-row 有效，供 PageView 翻页）
  const _FlatGridItem({required this.isHeader, this.date, this.photos, this.groupPhotos});
}