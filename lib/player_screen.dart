import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'app_layout.dart';
import 'app_theme.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_loader.dart';
import 'playback_recovery.dart';
import 'player_controls.dart';
import 'television_controls.dart';
import 'widgets.dart';
import 'sources_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController? _video;
  late final PlaybackLoader _loader;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  final _health = PlaybackHealth();
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Future<void> _operations = Future<void>.value();
  late int _index;
  int _openedIndex = -1;
  int _generation = 0;
  int _requestedQuality = 0;
  bool _loading = true;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _fullscreen = false;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _pendingError = false;
  String _loadingMessage = '正在准备播放';
  String? _error;
  PlaybackPlan? _plan;
  double _speed = 1;
  double _aspectRatio = 9 / 16;
  double _resumePosition = 0;
  bool _rotating = false;
  bool _television = false;
  bool get _mobile => !_television && (Platform.isAndroid || Platform.isIOS);
  String get _session => _plan?.session ?? '';
  double get _currentPosition =>
      _openedIndex == _index && _player.state.position.inMilliseconds > 0
      ? _player.state.position.inMilliseconds / 1000
      : _resumePosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex;
    _loader = PlaybackLoader(widget.repository);
    _player =
        widget.playerFactory?.call() ??
        Player(
          configuration: const PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
          ),
        );
    _video = widget.videoBuilder == null ? VideoController(_player) : null;
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          _queueRecovery();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_loading &&
            !_closed &&
            _acceptErrors &&
            _error == null) {
          final duration = _player.state.duration;
          if (duration <= Duration.zero ||
              _player.state.position < duration - const Duration(seconds: 2)) {
            _queueRecovery();
          } else if (_index + 1 < widget.detail.episodes.length) {
            _play(_index + 1);
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
        }
      }),
    );
    _subscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final width = parameters.dw ?? parameters.w ?? 0;
        final height = parameters.dh ?? parameters.h ?? 0;
        if (width > 0 && height > 0 && mounted && !_closed) {
          setState(() {
            _aspectRatio = width / height;
          });
        }
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_closed &&
          _acceptErrors &&
          !_loading &&
          _error == null &&
          _health.stalled(
            position: _player.state.position,
            playing: _player.state.playing && _playIntent,
            foreground: _foreground,
            now: DateTime.now(),
          )) {
        unawaited(_recover());
      }
    });
    _play(_index, position: widget.initialPosition);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final television = AppLayout.isTelevision(context);
    if (_television != television) {
      _television = television;
      if (Platform.isAndroid) {
        unawaited(
          SystemChrome.setEnabledSystemUIMode(
            television ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
          ),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _health.reset();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _playIntent = false;
      _player.pause();
      _saveProgress();
    }
    if (_foreground && _pendingError) {
      _queueRecovery();
    }
  }

  void _queueRecovery() {
    if (_closed || !_acceptErrors || _error != null) {
      return;
    }
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _generation;
    final position = _player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed || ticket != _generation || !_foreground || !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final state = _player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover());
    });
  }

  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    _errorTimer?.cancel();
    _pendingError = false;
    final position = _currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    if (action == PlaybackRecoveryAction.stop) {
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _generation) {
            return;
          }
          try {
            await _saveProgress();
            _openedIndex = -1;
            await _player.stop();
          } finally {
            await widget.repository.release(current.session);
          }
        });
      } catch (_) {}
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _localFailure = current.local;
          _error = current.local
              ? widget.allowOnlineFallback
                    ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                    : '本地成品读取失败，请重试或重新生成。'
              : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        });
      }
      return;
    }
    await _play(_index, position: position, recoveryAction: action);
  }

  void _togglePlayback() {
    _playIntent = !_player.state.playing;
    _health.reset();
    unawaited(_player.playOrPause());
  }

  Future<void> _saveProgress() async {
    if (_openedIndex < 0) {
      return;
    }
    final position = _player.state.position.inMilliseconds / 1000;
    final duration = _player.state.duration.inMilliseconds / 1000;
    if (position < .1) {
      return;
    }
    final store = widget.store;
    final entry = WatchEntry(
      drama: widget.detail.drama,
      episode: widget.detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await Future<void>.value();
      if (widget.mediaId == null) {
        await store.saveWatch(entry);
      } else {
        await store.saveMediaWatch(widget.mediaId!, entry);
      }
    } catch (_) {}
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    bool playWhenReady = true,
  }) async {
    if (_closed || index < 0 || index >= widget.detail.episodes.length) {
      return;
    }
    if (index != _index) _forceOnline = false;
    final ticket = ++_generation;
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recoveryAction == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _localFailure = false;
      _loadingMessage = switch (recoveryAction) {
        PlaybackRecoveryAction.alternative => '正在切换备用线路',
        PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
        _ => '正在准备播放',
      };
    });
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    bool installed = false;
    try {
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          return;
        }
        await _saveProgress();
        _openedIndex = -1;
        await _player.stop();
        final previous = _plan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null) {
          await widget.repository.release(previous.session);
        }
      });
      if (_closed || ticket != _generation) {
        return;
      }
      prepared = retained != null
          ? await _loader.fallback(retained!)
          : await _loader.load(
              widget.detail.drama,
              widget.detail.episodes[index],
              quality: _requestedQuality,
              localOnly: widget.localOnly,
              online: _forceOnline,
            );
      if (prepared == null) {
        return;
      }
      final plan = prepared;
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          await widget.repository.release(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        final platform = _player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await platform.setProperty('network-timeout', '20');
        }
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        await _player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: position > 0
                ? Duration(milliseconds: (position * 1000).round())
                : null,
          ),
          play: _foreground && _playIntent,
        );
        if (_closed || ticket != _generation) {
          return;
        }
        _openedIndex = index;
        _health.reset();
        await _player.setRate(_speed);
        if (mounted && !_closed && ticket == _generation) {
          setState(() {
            _loading = false;
          });
        }
      });
    } catch (error) {
      if (!_closed && mounted && ticket == _generation) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery();
        } else {
          if (prepared != null) {
            await widget.repository.release(prepared.session);
          }
          if (mounted && !_closed && ticket == _generation) {
            setState(() {
              _loading = false;
              _localFailure =
                  (error is AppFailure && error.code == 'local_media') ||
                  (widget.localOnly && !_forceOnline);
              _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
            });
          }
        }
      } else if (prepared != null && !installed) {
        await widget.repository.release(prepared.session);
      }
    } finally {
      if (retained != null) {
        await widget.repository.release(retained!.session);
      }
    }
  }

  Future<void> _switchOnline() async {
    _forceOnline = true;
    await _retry();
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _requestedQuality = quality;
    }
    await _play(
      _index,
      position: position,
      playWhenReady: quality == null || _error != null || _player.state.playing,
    );
  }

  bool get _showFullscreen =>
      _television ||
      _fullscreen ||
      (_mobile &&
          _aspectRatio >= 1 &&
          MediaQuery.orientationOf(context) == Orientation.landscape);

  Future<void> _rotate() async {
    if (_rotating || _television) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    _rotating = true;
    setState(() {
      _fullscreen = fullscreen;
    });
    try {
      if (Platform.isWindows) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        if (fullscreen) {
          await SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.immersiveSticky,
          );
          await SystemChrome.setPreferredOrientations(
            _aspectRatio >= 1
                ? [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ]
                : [
                    DeviceOrientation.portraitUp,
                    DeviceOrientation.portraitDown,
                  ],
          );
        } else {
          await SystemChrome.setPreferredOrientations(
            landscape
                ? [DeviceOrientation.portraitUp]
                : DeviceOrientation.values,
          );
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }
      }
    } finally {
      _rotating = false;
    }
  }

  void _seek(int seconds) {
    final desired = _player.state.position + Duration(seconds: seconds);
    final maxDuration = _player.state.duration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
        ? maxDuration
        : desired;
    _player.seek(target);
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    final index = await showDialog<int>(
      context: context,
      builder: (_) => TelevisionEpisodeDialog(
        episodes: widget.detail.episodes,
        currentIndex: _index,
      ),
    );
    if (index != null && mounted && !_closed && index != _index) {
      await _play(index);
    }
  }

  Future<void> _televisionSettings(BuildContext context) async {
    final selection = await showDialog<TelevisionPlaybackSetting>(
      context: context,
      builder: (_) => TelevisionSettingsDialog(
        speed: _speed,
        quality: _requestedQuality,
        qualities: _plan?.qualities ?? [],
        favorite: widget.store.isFavorite(widget.detail.drama.id),
        onFavorite: () => widget.store.toggleFavorite(widget.detail.drama),
      ),
    );
    if (selection == null || !mounted || _closed) return;
    if (selection.speed != null) {
      setState(() => _speed = selection.speed!);
      await _player.setRate(_speed);
    } else if (selection.quality != null &&
        selection.quality != _requestedQuality) {
      await _retry(quality: selection.quality);
    }
  }

  void _back() {
    if (_showFullscreen && !_television) {
      _rotate();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    unawaited(_saveProgress());
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(widget.repository.release(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) => _player.dispose()),
    );
    if (Platform.isWindows) {
      unawaited(windowManager.setFullScreen(false));
    } else if (_mobile) {
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    } else if (_television && Platform.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _television ? televisionTheme(AppTheme.dark) : AppTheme.dark,
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemBars(Brightness.dark),
      child: Builder(builder: _buildPlayer),
    ),
  );

  Widget _buildPlayer(BuildContext context) {
    final title = widget.detail.drama.title;
    final episode = widget.detail.episodes[_index];
    final fullscreen = _showFullscreen;
    return PopScope(
      canPop: _television || !fullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && fullscreen && !_television) {
          _rotate();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          const SingleActivator(LogicalKeyboardKey.goBack): _back,
          if (!_television) ...{
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _rotate,
            const SingleActivator(LogicalKeyboardKey.f11): _rotate,
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _seek(-10),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _seek(10),
            const SingleActivator(LogicalKeyboardKey.space): () =>
                _togglePlayback(),
          },
        },
        child: Focus(
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: fullscreen
                ? null
                : AppBar(
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    backgroundColor: const Color(0xFF101114),
                    actions: [
                      IconButton(
                        tooltip: '旋转与全屏',
                        onPressed: _rotate,
                        icon: const Icon(Icons.screen_rotation_alt_rounded),
                      ),
                    ],
                  ),
            body: SafeArea(
              top: fullscreen,
              bottom: true,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final desktop = constraints.maxWidth >= 840;
                  if (fullscreen) {
                    return _videoPane(context);
                  }
                  if (desktop ||
                      constraints.maxWidth > constraints.maxHeight * 1.3) {
                    return Row(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(child: _videoPane(context)),
                              _actionBar(episode),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: desktop ? 312 : 210,
                          child: _episodePanel(),
                        ),
                      ],
                    );
                  }
                  final height = (constraints.maxWidth / _aspectRatio).clamp(
                    0.0,
                    constraints.maxHeight * .64,
                  );
                  return Column(
                    children: [
                      SizedBox(
                        height: height,
                        width: double.infinity,
                        child: _videoPane(context),
                      ),
                      _actionBar(episode),
                      Expanded(child: _episodePanel()),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _videoPane(BuildContext context) {
    final title =
        '${widget.detail.drama.title} · 第 ${widget.detail.episodes[_index].number} 集${_plan?.local == true ? ' · 本地' : ''}${widget.detail.episodes[_index].vip ? ' · VIP 试看' : ''}${(_plan?.routeIndex ?? 0) > 0 ? ' · 线路 ${_plan!.routeIndex + 1}' : ''}';
    final Widget controls = _television
        ? TelevisionControls(
            player: _player,
            title: title,
            enabled: !_loading && _error == null,
            onTogglePlayback: _togglePlayback,
            onSeek: _seek,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
            onEpisodes: () => _televisionEpisodes(context),
            onSettings: () => _televisionSettings(context),
            onBack: _back,
          )
        : PlayerControls(
            player: _player,
            fullscreen: _showFullscreen,
            title: title,
            onTogglePlayback: _togglePlayback,
            swipeEnabled: _mobile,
            onFullscreen: _rotate,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.videoBuilder != null)
          widget.videoBuilder!(controls)
        else
          Video(
            controller: _video!,
            fit: BoxFit.contain,
            controls: (_) => controls,
          ),
        if (_loading)
          ColoredBox(
            color: Colors.black.withValues(alpha: .78),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_loadingMessage),
                ],
              ),
            ),
          ),
        if (_error != null)
          ColoredBox(
            color: Colors.black.withValues(alpha: .9),
            child: StatusPanel(
              title: '暂时无法播放',
              message: _error!,
              onRetry: () => _retry(),
              action: _localFailure ? '重试本地播放' : '重试播放',
              secondaryAction: _localFailure && widget.allowOnlineFallback
                  ? TextButton.icon(
                      onPressed: _switchOnline,
                      icon: const Icon(Icons.cloud_outlined),
                      label: const Text('改为在线播放'),
                    )
                  : !_localFailure &&
                        !widget.localOnly &&
                        widget.repository.supportsSourceManagement
                  ? SourceDiagnosticsButton(
                      repository: widget.repository,
                      store: widget.store,
                      drama: widget.detail.drama,
                    )
                  : null,
              icon: Icons.play_disabled_rounded,
            ),
          ),
      ],
    );
  }

  Widget _actionBar(Episode episode) => Container(
    color: const Color(0xFF191A20),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    child: Row(
      children: [
        IconButton(
          tooltip: '上一集',
          onPressed: _index > 0 ? () => _play(_index - 1) : null,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        Text('第 ${episode.number} 集'),
        IconButton(
          tooltip: '下一集',
          onPressed: _index + 1 < widget.detail.episodes.length
              ? () => _play(_index + 1)
              : null,
          icon: const Icon(Icons.skip_next_rounded),
        ),
        const Spacer(),
        PopupMenuButton<double>(
          tooltip: '播放倍速',
          initialValue: _speed,
          onSelected: (speed) {
            setState(() {
              _speed = speed;
            });
            _player.setRate(speed);
          },
          itemBuilder: (_) => [
            for (final speed in [.75, 1.0, 1.25, 1.5, 2.0])
              PopupMenuItem(value: speed, child: Text('${speed}x')),
          ],
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text('${_speed}x'),
          ),
        ),
        if ((_plan?.qualities.length ?? 0) > 1)
          PopupMenuButton<int>(
            tooltip: '清晰度',
            onSelected: (quality) => _retry(quality: quality),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 0, child: Text('自动（优先高清）')),
              for (final quality in _plan!.qualities)
                PopupMenuItem(value: quality, child: Text('${quality}P')),
            ],
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(_plan!.quality > 0 ? '${_plan!.quality}P' : '自动'),
            ),
          ),
      ],
    ),
  );

  Widget _episodePanel() => Container(
    color: const Color(0xFF101114),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选集 · 共 ${widget.detail.episodes.length} 集',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              AnimatedBuilder(
                animation: widget.store,
                builder: (context, _) => TextButton.icon(
                  onPressed: () =>
                      widget.store.toggleFavorite(widget.detail.drama),
                  icon: Icon(
                    widget.store.isFavorite(widget.detail.drama.id)
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                    size: 18,
                  ),
                  label: Text(
                    widget.store.isFavorite(widget.detail.drama.id)
                        ? '已追剧'
                        : '追剧',
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 76,
              mainAxisExtent: 46,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: widget.detail.episodes.length,
            itemBuilder: (_, index) {
              final episode = widget.detail.episodes[index];
              return TextButton(
                key: ValueKey('play-episode-${episode.number}'),
                onPressed: () => _play(index),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: index == _index
                      ? const Color(0xFF763D32)
                      : const Color(0xFF24252C),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (index == _index)
                      const Icon(Icons.equalizer_rounded, size: 14),
                    Text('${episode.number}'),
                    if (episode.vip)
                      const Icon(
                        Icons.workspace_premium_rounded,
                        color: Color(0xFFF6C86B),
                        size: 13,
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
