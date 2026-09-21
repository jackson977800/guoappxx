import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'background_downloads.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'media_pipeline.dart';
import 'models.dart';

class LocalMediaItem {
  LocalMediaItem({
    required this.id,
    required this.drama,
    required this.file,
    required this.kind,
    required this.episodes,
    required this.duration,
    required this.bytes,
    required this.created,
    this.videoTranscodes = 0,
    this.audioTranscodes = 0,
    this.jobId = '',
    this.sourceVersion = '',
  });
  final String id, file, kind, jobId, sourceVersion;
  final Drama drama;
  final List<int> episodes;
  final double duration;
  final int bytes, videoTranscodes, audioTranscodes;
  final DateTime created;
  bool get merged => kind == 'merged';
  Map<String, dynamic> toJson() => {
    'id': id,
    'drama': drama.toJson(),
    'file': file,
    'kind': kind,
    'episodes': episodes,
    'duration': duration,
    'bytes': bytes,
    'created': created.toIso8601String(),
    'videoTranscodes': videoTranscodes,
    'audioTranscodes': audioTranscodes,
    'jobId': jobId,
    'sourceVersion': sourceVersion,
  };
  factory LocalMediaItem.fromJson(Map<String, dynamic> value) {
    final file = value['file'] as String;
    if (path.isAbsolute(file) || file.split(RegExp(r'[/\\]')).contains('..')) {
      throw const FormatException('媒体路径无效');
    }
    return LocalMediaItem(
      id: value['id'] as String,
      drama: Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
      file: file,
      kind: value['kind'] as String,
      episodes: (value['episodes'] as List).map(intValue).toList(),
      duration: (value['duration'] as num).toDouble(),
      bytes: intValue(value['bytes']),
      created: DateTime.parse(value['created'] as String),
      videoTranscodes: intValue(value['videoTranscodes']),
      audioTranscodes: intValue(value['audioTranscodes']),
      jobId: value['jobId'] as String? ?? '',
      sourceVersion: value['sourceVersion'] as String? ?? '',
    );
  }
}

String xmlText(String value) => value
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String embyShowNfo(Drama drama, {bool localPoster = false}) {
  final uri = Uri.tryParse(drama.cover);
  final cover = localPoster
      ? 'poster.jpg'
      : uri != null && {'https', 'http'}.contains(uri.scheme)
      ? drama.cover
      : '';
  return '<?xml version="1.0" encoding="utf-8"?>\n<tvshow>'
      '<title>${xmlText(drama.title)}</title><plot>${xmlText(drama.description)}</plot>'
      '<uniqueid type="zhenguojian" default="true">${xmlText(drama.id)}</uniqueid>'
      '${cover.isEmpty ? '' : '<thumb aspect="poster">${xmlText(cover)}</thumb>'}'
      '<season>1</season><episode>${drama.episodes}</episode></tvshow>\n';
}

String embyEpisodeNfo(DownloadJob job) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<episodedetails><title>${xmlText(job.episode.title)}</title>'
    '<showtitle>${xmlText(job.drama.title)}</showtitle><season>1</season><episode>${job.episode.number}</episode>'
    '<plot>${xmlText(job.drama.description)}</plot>'
    '<uniqueid type="zhenguojian" default="true">${xmlText(job.id)}</uniqueid></episodedetails>\n';

String _safeName(String name) {
  var result = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty) result = '短剧';
  return String.fromCharCodes(result.runes.take(60));
}

class MediaLibrary extends ChangeNotifier {
  MediaLibrary(
    this.repository,
    this.store, {
    MediaExecutor? executor,
    this.automaticWorker = false,
  }) : executor = executor ?? FFmpegExecutor();
  final AppRepository repository;
  final LocalStore store;
  final MediaExecutor executor;
  final bool automaticWorker;
  static MediaLibrary? current;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Timer? _timer;
  MediaLibrary? _automatic;
  String? root;
  List<LocalMediaItem> _items = [];
  final _skipped = <String>{};
  bool busy = false, _checking = false, _cancelled = false, _suspended = false;
  bool get suspended => _suspended;
  set suspended(bool value) {
    _suspended = value;
    _automatic?.suspended = value;
  }

  String status = '', error = '';
  double progress = 0;
  DateTime _retryAfter = DateTime(2000);

  static void attach(AppRepository repository, LocalStore store) {
    current?.dispose();
    final library = MediaLibrary(repository, store);
    current = library;
    if (Platform.isAndroid && store.autoExport) {
      unawaited(
        BackgroundDownloads.ensureStarted().catchError((Object error) {
          library.error = error.toString();
        }),
      );
    }
    if (!Platform.isAndroid) {
      final automatic = MediaLibrary(
        repository is NativeRepository
            ? NativeRepository(background: true)
            : repository,
        store,
        automaticWorker: true,
      );
      library._automatic = automatic;
      library._timer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => unawaited(automatic.maybeExport()),
      );
    }
  }

  List<LocalMediaItem> get items =>
      _items
          .where(
            (item) =>
                store.canDownload && store.allowsSource(item.drama.source),
          )
          .toList()
        ..sort((a, b) => b.created.compareTo(a.created));
  String fileFor(LocalMediaItem item) {
    if (root == null) throw AppFailure('媒体目录尚未就绪');
    final file = path.join(root!, item.file);
    if (!path.isWithin(root!, file)) throw AppFailure('媒体路径无效');
    return file;
  }

  Future<void> reload() async {
    root = await repository.downloadDirectory();
    if (root!.isEmpty) throw AppFailure('无法读取下载位置');
    final file = File(path.join(root!, 'media-library.json'));
    _items = [];
    _skipped.clear();
    if (await file.exists()) {
      if (await file.length() > 16 * 1024 * 1024) {
        throw AppFailure('本地媒体记录过大，原文件已保留');
      }
      final data = jsonDecode(await file.readAsString()) as Map;
      _items = (data['items'] as List)
          .map(
            (v) => LocalMediaItem.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
      _skipped.addAll((data['skipped'] as List? ?? []).cast<String>());
    }
    notifyListeners();
  }

  Future<void> _writeText(File target, String content) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.writing');
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(target.path);
  }

  Future<void> _save() async {
    await _writeText(
      File(path.join(root!, 'media-library.json')),
      jsonEncode({
        'items': _items.map((item) => item.toJson()).toList(),
        'skipped': _skipped.toList(),
      }),
    );
  }

  void _check() {
    if (_cancelled || suspended) throw AppFailure('已取消本地媒体处理');
  }

  Future<T> _task<T>(
    String name,
    Future<T> Function(Directory temporary) action,
  ) async {
    if (busy) throw AppFailure('已有本地媒体任务正在处理');
    busy = true;
    status = name;
    error = '';
    progress = 0;
    _cancelled = false;
    notifyListeners();
    Directory? temporary;
    bool lease = false;
    try {
      if (!automaticWorker) await BackgroundDownloads.ensureStarted();
      await repository.workLease('media', 'start');
      lease = true;
      await reload();
      for (final entry in Directory(root!).listSync(followLinks: false)) {
        if (entry is Directory &&
            path.basename(entry.path).startsWith('.media-work-')) {
          await entry.delete(recursive: true);
        }
      }
      temporary = await Directory(root!).createTemp('.media-work-');
      _check();
      final result = await action(temporary);
      progress = 1;
      status = '处理完成';
      return result;
    } catch (failure) {
      error = failure.toString();
      status = _cancelled ? '已取消' : '处理未完成';
      rethrow;
    } finally {
      if (temporary != null && await temporary.exists()) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
      if (lease) {
        try {
          await repository.workLease('media', 'end');
        } catch (_) {}
      }
      busy = false;
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    await Future.wait([
      executor.cancel(),
      if (_automatic != null) _automatic!.cancel(),
    ]);
  }

  Future<MediaProbe> _prepare(
    DownloadJob job,
    String destination,
    double base,
    double weight,
  ) async {
    _check();
    final plan = await repository.localPlayback(job.drama, job.episode);
    _check();
    if (plan == null || !plan.local) {
      throw AppFailure('第 ${job.episode.number} 集尚未完整下载');
    }
    status = '读取第 ${job.episode.number} 集';
    notifyListeners();
    final input = <String>[];
    if (plan.decryptionKey.isNotEmpty) {
      input.addAll(['-decryption_key', plan.decryptionKey]);
    }
    if (path.extension(plan.url).toLowerCase() == '.m3u8') {
      input.addAll(['-allowed_extensions', 'ALL', '-extension_picky', '0']);
    }
    await executor.run([
      ...input,
      '-i',
      plan.url,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-c',
      'copy',
      '-map_metadata',
      '-1',
      '-avoid_negative_ts',
      'make_zero',
      destination,
    ]);
    _check();
    final probe = await executor.probe(destination);
    _check();
    verifyMediaDuration(probe, 0);
    progress = base + weight;
    notifyListeners();
    return probe;
  }

  Future<LocalMediaItem> merge(List<DownloadJob> selected) async {
    final jobs = selected.where((job) => job.completed).toList()
      ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    if (jobs.length < 2 ||
        jobs.map((job) => job.drama.id).toSet().length != 1 ||
        jobs.map((job) => job.episode.number).toSet().length != jobs.length) {
      throw AppFailure('请选择同一部剧至少两集已下载的视频');
    }
    return _task('准备合并', (temporary) async {
      final prepared = <String>[], probes = <MediaProbe>[];
      for (var i = 0; i < jobs.length; i++) {
        final target = path.join(temporary.path, 'original-$i.mkv');
        probes.add(
          await _prepare(
            jobs[i],
            target,
            .25 * i / jobs.length,
            .25 / jobs.length,
          ),
        );
        prepared.add(target);
      }
      final plan = MergePlan.create(probes);
      final normalized = <String>[];
      for (var i = 0; i < jobs.length; i++) {
        _check();
        status = plan.videoChanges[i]
            ? '统一第 ${jobs[i].episode.number} 集视频格式'
            : plan.audioChanges[i]
            ? '统一第 ${jobs[i].episode.number} 集音轨'
            : '保留第 ${jobs[i].episode.number} 集码流';
        notifyListeners();
        final target = path.join(
          temporary.path,
          'part-$i.${plan.transportStream ? 'ts' : 'mkv'}',
        );
        await executor.run(
          plan.normalizeArguments(prepared[i], target, probes[i], i),
          duration: probes[i].duration,
          progress: (value) {
            progress = .25 + .55 * (i + value) / jobs.length;
            notifyListeners();
          },
        );
        _check();
        final checked = await executor.probe(target);
        _check();
        verifyMediaDuration(checked, probes[i].duration);
        normalized.add(target);
        await File(prepared[i]).delete();
      }
      _check();
      status = '合并视频';
      notifyListeners();
      final list = File(path.join(temporary.path, 'concat.txt'));
      await list.writeAsString(
        'ffconcat version 1.0\n${normalized.map(concatFileLine).join('\n')}\n',
        flush: true,
      );
      final output = path.join(temporary.path, 'full.mkv');
      final duration = probes.fold<double>(
        0,
        (sum, probe) => sum + probe.duration,
      );
      await executor.run(
        [
          '-f',
          'concat',
          '-safe',
          '0',
          '-i',
          list.path,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-c',
          'copy',
          '-avoid_negative_ts',
          'make_zero',
          output,
        ],
        duration: duration,
        progress: (value) {
          progress = .8 + value * .19;
          notifyListeners();
        },
      );
      _check();
      final checked = await executor.probe(output);
      _check();
      verifyMediaDuration(checked, duration);
      final id = 'merged-${DateTime.now().microsecondsSinceEpoch}';
      final relative = path.join('library', id, 'full.mkv');
      final target = File(path.join(root!, relative));
      await target.parent.create(recursive: true);
      await File(output).rename(target.path);
      final item = LocalMediaItem(
        id: id,
        drama: jobs.first.drama,
        file: relative,
        kind: 'merged',
        episodes: jobs.map((job) => job.episode.number).toList(),
        duration: checked.duration,
        bytes: await target.length(),
        created: DateTime.now(),
        videoTranscodes: plan.videoTranscodes,
        audioTranscodes: plan.audioTranscodes,
      );
      _items.add(item);
      try {
        await _save();
      } catch (_) {
        _items.remove(item);
        await target.parent.delete(recursive: true);
        rethrow;
      }
      return item;
    });
  }

  String _sourceVersion(DownloadJob job) =>
      '${job.created}-${job.bytes}-${job.actualQuality}';

  Future<void> _exportMetadata(DownloadJob job, File target) async {
    final showDirectory = target.parent.parent;
    final poster = File(path.join(showDirectory.path, 'poster.jpg'));
    var hasPoster = await poster.exists();
    if (store.exportPosters &&
        !hasPoster &&
        !const bool.fromEnvironment('DISABLE_REMOTE_IMAGES')) {
      try {
        final cover = await repository.cover(job.drama);
        _check();
        await File(cover).copy(poster.path);
        hasPoster = true;
      } catch (_) {}
    }
    _check();
    await _writeText(
      File(path.join(showDirectory.path, 'tvshow.nfo')),
      embyShowNfo(job.drama, localPoster: hasPoster),
    );
    await _writeText(
      File(path.setExtension(target.path, '.nfo')),
      embyEpisodeNfo(job),
    );
  }

  Future<void> exportJobs(
    List<DownloadJob> selected, {
    bool automatic = false,
  }) async {
    final jobs = selected.where((job) => job.completed).toList()
      ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    if (jobs.isEmpty) throw AppFailure('没有已下载的分集');
    await _task('准备导出 Emby', (temporary) async {
      for (var i = 0; i < jobs.length; i++) {
        _check();
        final job = jobs[i], id = 'export-${jobs[i].id}';
        if (automatic && _skipped.contains(job.id)) continue;
        final existing = _items.where((item) => item.id == id).firstOrNull;
        if (existing?.sourceVersion == _sourceVersion(job) &&
            await File(fileFor(existing!)).exists()) {
          if (!automatic) {
            await _exportMetadata(job, File(fileFor(existing)));
          }
          progress = (i + 1) / jobs.length;
          notifyListeners();
          continue;
        }
        final intermediate = path.join(temporary.path, 'export-$i.mkv');
        final probe = await _prepare(
          job,
          intermediate,
          i / jobs.length,
          .8 / jobs.length,
        );
        _check();
        status = '导出第 ${job.episode.number} 集';
        notifyListeners();
        final showId = sha256
            .convert(utf8.encode(job.drama.id))
            .toString()
            .substring(0, 12);
        final show = path.join(
          'exports',
          '${_safeName(job.drama.title)} [${job.drama.source}-$showId]',
        );
        final relative = path.join(
          show,
          'Season 01',
          'S01E${job.episode.number.toString().padLeft(3, '0')}.mkv',
        );
        final target = File(path.join(root!, relative));
        await target.parent.create(recursive: true);
        await File(intermediate).rename(target.path);
        await _exportMetadata(job, target);
        _items.removeWhere((item) => item.id == id);
        _items.add(
          LocalMediaItem(
            id: id,
            drama: job.drama,
            file: relative,
            kind: 'export',
            episodes: [job.episode.number],
            duration: probe.duration,
            bytes: await target.length(),
            created: DateTime.now(),
            jobId: job.id,
            sourceVersion: _sourceVersion(job),
          ),
        );
        _skipped.remove(job.id);
        await _save();
        progress = (i + 1) / jobs.length;
        notifyListeners();
      }
    });
  }

  Future<void> maybeExport() async {
    if (_checking ||
        busy ||
        suspended ||
        DateTime.now().isBefore(_retryAfter)) {
      return;
    }
    _checking = true;
    try {
      if (automaticWorker) await store.reload();
      if (!store.autoExport) return;
      final jobs = await repository.downloads();
      if (!jobs.any((job) => job.completed)) return;
      await reload();
      final pending = <DownloadJob>[];
      for (final job in jobs.where(
        (job) => job.completed && !_skipped.contains(job.id),
      )) {
        final item = _items
            .where((item) => item.id == 'export-${job.id}')
            .firstOrNull;
        if (item == null ||
            item.sourceVersion != _sourceVersion(job) ||
            !await File(fileFor(item)).exists()) {
          pending.add(job);
        }
      }
      if (pending.isNotEmpty) await exportJobs(pending, automatic: true);
    } catch (failure) {
      _retryAfter = DateTime.now().add(const Duration(minutes: 2));
      error = failure.toString();
    } finally {
      _checking = false;
    }
  }

  Future<void> remove(LocalMediaItem selected) async {
    await _task('删除本地媒体', (_) async {
      final item = _items.where((item) => item.id == selected.id).firstOrNull;
      if (item == null) return;
      final file = File(fileFor(item));
      if (item.merged) {
        if (await file.parent.exists()) {
          await file.parent.delete(recursive: true);
        }
      } else {
        if (await file.exists()) await file.delete();
        final metadata = File(path.setExtension(file.path, '.nfo'));
        if (await metadata.exists()) await metadata.delete();
        _skipped.add(item.jobId);
      }
      _items.removeWhere((entry) => entry.id == item.id);
      if (!item.merged &&
          !_items.any(
            (other) => !other.merged && other.drama.id == item.drama.id,
          )) {
        final show = file.parent.parent;
        if (await show.exists()) await show.delete(recursive: true);
      }
      await _save();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    _timer?.cancel();
    _automatic?.dispose();
    unawaited(executor.cancel());
    super.dispose();
  }
}
