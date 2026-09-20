import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'app_bottom_navigation.dart';
import 'core_bridge.dart';
import 'catalog_filters.dart';
import 'detail_screen.dart';
import 'downloads_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'settings_screen.dart';
import 'profiles_screen.dart';
import 'search_input.dart';
import 'sources_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  late SourceSite _source;
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _page = 1;
  int _generation = 0;
  int _tab = 0;
  String _submittedQuery = '';
  bool _failedMore = false;
  final _categorySelections = <String, String>{};
  final _categoryOptions = <String, List<CatalogCategory>>{};
  final _groupSources = <String, String>{};
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;

  String get _category => _categorySelections[_source.id] ?? '';
  String get _requestCategory =>
      _category.startsWith('local:') ? '' : _category;
  List<SourceGroup> get _sourceGroups =>
      SourceGroup.fromSources(widget.store.sources);
  List<CatalogCategory> get _categories {
    final remote = _categoryOptions[_source.id] ?? const [CatalogCategory.all];
    if (remote.length > 1) return remote;
    final names =
        _items
            .map((item) => item.category.trim())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return [
      CatalogCategory.all,
      for (final name in names)
        CatalogCategory('local:$name', name, local: true),
    ];
  }

  Future<void> _loadCategories({bool force = false}) async {
    final generation = ++_categoryGeneration;
    final source = _source.id;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    try {
      final categories = await widget.repository.categories(
        source,
        force: force,
      );
      if (!mounted ||
          generation != _categoryGeneration ||
          source != _source.id) {
        return;
      }
      setState(() {
        _categoryOptions[source] = [
          CatalogCategory.all,
          ...categories.where((entry) => entry.id.isNotEmpty),
        ];
        _categoriesLoading = false;
      });
      if (_category.isNotEmpty &&
          !_category.startsWith('local:') &&
          !_categories.any((entry) => entry.id == _category)) {
        _changeCategory('');
      }
    } catch (error) {
      if (mounted &&
          generation == _categoryGeneration &&
          source == _source.id) {
        setState(() {
          _categoriesLoading = false;
          _categoriesError = error.toString();
        });
      }
    }
  }

  Future<void> _refreshCatalog() async {
    await Future.wait([_loadCategories(force: true), _load(force: true)]);
  }

  void _changeGroup(SourceGroup group) {
    if (_source.groupId == group.id) return;
    final previous = _groupSources[group.id];
    _changeSource(
      group.sources.where((entry) => entry.id == previous).firstOrNull ??
          group.sources.first,
    );
  }

  void _changeCategory(String category) {
    if (_category == category) return;
    final before = _requestCategory;
    final hadSearch = _source.onlineSearch && _search.text.isNotEmpty;
    setState(() {
      _categorySelections[_source.id] = category;
      if (hadSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      if (before != _requestCategory || hadSearch) {
        _items = [];
        _hasMore = true;
        _page = 1;
        _error = null;
      }
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (before != _requestCategory || hadSearch) _load(useCache: true);
  }

  Future<void> _manageSources() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcesScreen(
          repository: widget.repository,
          store: widget.store,
          initialSource: _source.id,
        ),
      ),
    );
    if (!mounted || _source.onlineSearch && _submittedQuery.isNotEmpty) return;
    final source = _source.id;
    final generation = ++_generation;
    try {
      final cached = await widget.repository.cached(
        source,
        category: _requestCategory,
      );
      if (!mounted || generation != _generation || source != _source.id) return;
      setState(() {
        if (cached.items.isNotEmpty) {
          _items = cached.items;
          _page = cached.page;
          _hasMore = cached.hasMore;
        }
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _chooseDisplayMode() async {
    final selection = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('界面模式'),
        children: [
          RadioGroup<String>(
            groupValue: widget.store.displayMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in const {
                  'auto': '自动识别设备',
                  'television': '电视 / 遥控器',
                  'standard': '手机 / 电脑',
                }.entries)
                  RadioListTile<String>(
                    value: mode.key,
                    autofocus: mode.key == widget.store.displayMode,
                    title: Text(mode.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selection != null && mounted) {
      await widget.store.setDisplayMode(selection);
    }
  }

  Future<void> _televisionSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: _source.onlineSearch ? '搜索红果短剧' : '筛选当前已加载短剧',
        suggestions: _source.onlineSearch
            ? widget.repository.suggestions
            : null,
      ),
    );
    if (query != null && mounted) {
      _search.text = query;
      _debounce?.cancel();
      if (_source.onlineSearch) {
        _load();
      } else {
        setState(() {});
      }
    }
  }

  void _televisionBack() {
    if (_tab != 0) {
      setState(() => _tab = 0);
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }

  @override
  void initState() {
    super.initState();
    _source = SourceSite.byId(widget.store.source);
    _groupSources[_source.groupId] = _source.id;
    if (widget.store.sources.isNotEmpty) {
      _load(useCache: true);
      _loadCategories();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _categoryGeneration++;
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
  }) async {
    if (more && (_loading || _loadingMore || !_hasMore)) {
      return;
    }
    final generation = ++_generation;
    final source = _source;
    final category = _requestCategory;
    final query = source.onlineSearch ? _search.text.trim() : '';
    final page = more ? _page + 1 : 1;
    setState(() {
      _error = null;
      _failedMore = false;
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery) {
          _items = [];
        }
      }
    });
    if (useCache && !force && query.isEmpty) {
      try {
        final cached = await widget.repository.cached(
          source.id,
          category: category,
        );
        if (!mounted || generation != _generation) {
          return;
        }
        if (cached.items.isNotEmpty) {
          setState(() {
            _items = cached.items;
            _page = cached.page;
            _hasMore = cached.hasMore;
            _submittedQuery = query;
            _loading = !cached.fresh;
          });
          if (cached.fresh) {
            return;
          }
        }
      } catch (_) {}
    }
    try {
      final result = await widget.repository.catalog(
        source.id,
        page: page,
        query: query,
        category: category,
        force: force,
      );
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        final entries = <String, Drama>{};
        if (more) {
          for (final item in _items) {
            entries[item.id] = item;
          }
        }
        for (final item in result.items) {
          entries[item.id] = item;
        }
        _items = entries.values.toList();
        _page = result.page;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        _loading = false;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
        _failedMore = more;
      });
    }
  }

  void _changeSource(SourceSite source) {
    if (_source.id == source.id) {
      return;
    }
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _source = source;
      _groupSources[source.groupId] = source.id;
      _items = [];
      _hasMore = true;
      _page = 1;
      _submittedQuery = '';
      _error = null;
    });
    widget.store.setSource(source.id);
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    _load(useCache: true);
    _loadCategories();
  }

  void _searchChanged(String query) {
    _debounce?.cancel();
    setState(() {});
    if (_source.onlineSearch && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _load());
    }
  }

  void _openDrama(Drama drama) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  bool get _supportsVipFilter => _source.id == 'huangdou';
  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;

  List<Drama> get _visible {
    final query = _search.text.trim().toLowerCase();
    return _items.where((drama) {
      if (!widget.store.allowsSource(drama.source)) return false;
      if (_category.startsWith('local:') &&
          drama.category.trim() != _category.substring(6)) {
        return false;
      }
      if (_hideVip && drama.vip) {
        return false;
      }
      return _source.onlineSearch ||
          query.isEmpty ||
          ('${drama.title} ${drama.description}').toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final television = AppLayout.isTelevision(context);
        final desktop = constraints.maxWidth >= 840;
        final scaffold = Scaffold(
          appBar: AppBar(
            toolbarHeight: television ? 64 : null,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.play_circle_filled_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 30,
                ),
                const SizedBox(width: 9),
                const Text(
                  appName,
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            actions: [
              if (_tab == 0)
                RefreshAction(
                  key: const ValueKey('catalog-refresh'),
                  loading: _loading || _loadingMore || _categoriesLoading,
                  tooltip: '更新当前站源',
                  onPressed: widget.store.sources.isEmpty
                      ? null
                      : _refreshCatalog,
                ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  if (value == 'sources') {
                    _manageSources();
                  } else if (value == 'settings') {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(
                          repository: widget.repository,
                          store: widget.store,
                        ),
                      ),
                    );
                  } else if (value == 'users') {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ProfilesScreen(store: widget.store),
                      ),
                    );
                  } else if (value == 'display') {
                    _chooseDisplayMode();
                  } else if (value == 'about') {
                    showAboutDialog(
                      context: context,
                      applicationName: appName,
                      applicationVersion: AppLayout.versionOf(context),
                      applicationIcon: const Icon(
                        Icons.play_circle_filled_rounded,
                        size: 48,
                        color: Color(0xFFFF765F),
                      ),
                      children: [
                        const Text('独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。'),
                      ],
                    );
                  }
                },
                itemBuilder: (_) => [
                  if (widget.repository.supportsSourceManagement)
                    const PopupMenuItem(value: 'sources', child: Text('站源管理')),
                  const PopupMenuItem(value: 'users', child: Text('用户管理')),
                  const PopupMenuItem(value: 'settings', child: Text('设置与备份')),
                  const PopupMenuItem(value: 'display', child: Text('界面模式')),
                  const PopupMenuItem(
                    value: 'about',
                    child: Text('关于$appName'),
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Row(
              children: [
                if (television) ...[
                  SizedBox(
                    width: 164,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in [
                            (Icons.explore_rounded, '发现'),
                            (Icons.bookmark_rounded, '追剧'),
                            (Icons.history_rounded, '最近观看'),
                            if (widget.store.canDownload)
                              (Icons.download_rounded, '下载'),
                          ].indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: RemoteButton(
                                key: ValueKey('tv-nav-${entry.$1}'),
                                label: entry.$2.$2,
                                icon: entry.$2.$1,
                                selected: _tab == entry.$1,
                                autofocus: entry.$1 == 0,
                                onPressed: () =>
                                    setState(() => _tab = entry.$1),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ] else if (desktop) ...[
                  NavigationRail(
                    selectedIndex: _tab,
                    onDestinationSelected: (value) => setState(() {
                      _tab = value;
                    }),
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -.8,
                    destinations: [
                      NavigationRailDestination(
                        icon: Icon(Icons.explore_outlined),
                        selectedIcon: Icon(Icons.explore),
                        label: Text('发现'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.bookmark_border_rounded),
                        selectedIcon: Icon(Icons.bookmark_rounded),
                        label: Text('追剧'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.history_rounded),
                        label: Text('最近观看'),
                      ),
                      if (widget.store.canDownload)
                        NavigationRailDestination(
                          icon: Icon(Icons.download_outlined),
                          selectedIcon: Icon(Icons.download_rounded),
                          label: Text('下载'),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                ],
                Expanded(
                  child: _tab == 0
                      ? widget.store.sources.isEmpty
                            ? const StatusPanel(
                                title: '暂无可用站源',
                                message: '请联系管理员为当前用户开放站源。',
                              )
                            : _catalog()
                      : _tab == 3
                      ? DownloadsScreen(
                          repository: widget.repository,
                          store: widget.store,
                          embedded: true,
                        )
                      : _saved(),
                ),
              ],
            ),
          ),
          bottomNavigationBar: desktop || television
              ? null
              : AppBottomNavigation(
                  selectedIndex: _tab,
                  onDestinationSelected: (value) => setState(() {
                    _tab = value;
                  }),
                  destinations: [
                    NavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore),
                      label: '发现',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.bookmark_border_rounded),
                      selectedIcon: Icon(Icons.bookmark_rounded),
                      label: '追剧',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.history_rounded),
                      label: '最近观看',
                    ),
                    if (widget.store.canDownload)
                      NavigationDestination(
                        icon: Icon(Icons.download_outlined),
                        selectedIcon: Icon(Icons.download_rounded),
                        label: '下载',
                      ),
                  ],
                ),
        );
        if (!television) return scaffold;
        return PopScope(
          canPop: _tab == 0 && _search.text.isEmpty,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _televisionBack();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).maybePop(),
              const SingleActivator(LogicalKeyboardKey.goBack): () =>
                  Navigator.of(context).maybePop(),
            },
            child: scaffold,
          ),
        );
      },
    ),
  );

  Widget _catalog() {
    final items = _visible;
    final television = AppLayout.isTelevision(context);
    return Column(
      children: [
        if (television)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: RemoteButton(
                label: '搜索',
                icon: Icons.search_rounded,
                onPressed: _televisionSearch,
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SearchInput(
              key: ValueKey('search-${_source.id}'),
              controller: _search,
              hint: _source.onlineSearch ? '搜索红果短剧' : '筛选当前已加载短剧',
              suggestions: _source.onlineSearch
                  ? widget.repository.suggestions
                  : null,
              onChanged: _searchChanged,
              onSearch: (_) {
                _debounce?.cancel();
                if (_source.onlineSearch) {
                  _load();
                } else {
                  setState(() {});
                }
              },
            ),
          ),
        CatalogFilters(
          groups: _sourceGroups,
          source: _source,
          categories: _categories,
          category: _category,
          loading: _categoriesLoading,
          error: _categoriesError,
          onGroup: _changeGroup,
          onSource: _changeSource,
          onCategory: _changeCategory,
          onRetry: () => _loadCategories(force: true),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _submittedQuery.isNotEmpty && _source.onlineSearch
                      ? '搜索结果 · ${items.length} 部'
                      : '${_source.description} · ${items.length} 部',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: television ? 14 : 12,
                  ),
                ),
              ),
              if (_supportsVipFilter)
                Tooltip(
                  message: widget.store.hideVip ? '当前隐藏 VIP 内容' : '当前显示 VIP 内容',
                  child: TextButton.icon(
                    onPressed: () =>
                        widget.store.setHideVip(!widget.store.hideVip),
                    icon: Icon(
                      widget.store.hideVip
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 17,
                    ),
                    label: Text(widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示'),
                  ),
                ),
            ],
          ),
        ),
        if (_loading && _items.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        if (_error != null && _items.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _loading || _loadingMore
                      ? null
                      : () => _load(more: _failedMore, force: true),
                  child: const Text('重试'),
                ),
                if (widget.repository.supportsSourceManagement)
                  IconButton(
                    tooltip: '站源诊断',
                    onPressed: _manageSources,
                    icon: const Icon(Icons.network_check),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _loading && _items.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 18),
                      Text('正在加载剧集'),
                    ],
                  ),
                )
              : _items.isEmpty && _error != null
              ? StatusPanel(
                  title: '暂时无法加载',
                  message: _error!,
                  onRetry: () => _load(force: true),
                  secondaryAction: widget.repository.supportsSourceManagement
                      ? TextButton(
                          onPressed: _manageSources,
                          child: const Text('站源诊断'),
                        )
                      : null,
                  icon: Icons.wifi_off_rounded,
                )
              : items.isEmpty
              ? StatusPanel(
                  title: '没有找到匹配的短剧',
                  message: _hideVip
                      ? '可以换个搜索词，或显示 VIP 内容。'
                      : widget.store.sources.length > 1
                      ? '可以换个搜索词或切换站源。'
                      : '可以换个搜索词，或刷新后重试。',
                  onRetry:
                      _hasMore &&
                          !_loadingMore &&
                          (!_source.onlineSearch || _search.text.isEmpty)
                      ? () => _load(more: true)
                      : null,
                  action: '加载更多',
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (television) {
                      return _televisionGrid(
                        items,
                        constraints.maxWidth,
                        key: 'catalog-${_source.id}-$_submittedQuery',
                        controller: _scroll,
                        footer: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                          child: Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator()
                                : _hasMore
                                ? RemoteButton(
                                    label: '加载更多',
                                    icon: Icons.expand_more,
                                    onPressed: () => _load(more: true),
                                  )
                                : const Text('已经看到这里的全部剧集'),
                          ),
                        ),
                      );
                    }
                    final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
                    return RefreshIndicator(
                      onRefresh: _refreshCatalog,
                      child: CustomScrollView(
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              0,
                              padding,
                              16,
                            ),
                            sliver: SliverGrid(
                              gridDelegate: dramaGridDelegate(
                                context,
                                constraints.maxWidth - 2 * padding,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (_, index) => DramaTile(
                                  key: ValueKey(items[index].id),
                                  drama: items[index],
                                  repository: widget.repository,
                                  onTap: () => _openDrama(items[index]),
                                ),
                                childCount: items.length,
                              ),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 24),
                              child: Center(
                                child: _loadingMore
                                    ? const CircularProgressIndicator()
                                    : _hasMore
                                    ? OutlinedButton.icon(
                                        onPressed: () => _load(more: true),
                                        icon: const Icon(
                                          Icons.expand_more_rounded,
                                        ),
                                        label: const Text('加载更多'),
                                      )
                                    : Text(
                                        '已经看到这里的全部剧集',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _saved() {
    final history = widget.store.history;
    final items = _tab == 1
        ? widget.store.favorites
        : history.map((entry) => entry.drama).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 20),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tab == 1 ? '我的追剧' : '最近观看',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _tab == 1 ? '收藏喜欢的剧，随时接着看' : '点击剧集，继续上次的进度',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (_tab == 2 && items.isNotEmpty)
                IconButton(
                  tooltip: '清空观看记录',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    final accepted = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('清空观看记录？'),
                        content: const Text('这会删除当前设备保存的观看进度。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('清空'),
                          ),
                        ],
                      ),
                    );
                    if (accepted == true) {
                      await widget.store.clearHistory();
                    }
                  },
                ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? StatusPanel(
                  title: _tab == 1 ? '还没有追剧' : '还没有观看记录',
                  message: '去发现页，挑一部喜欢的短剧。',
                  icon: _tab == 1
                      ? Icons.bookmark_border_rounded
                      : Icons.history_rounded,
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (AppLayout.isTelevision(context)) {
                      return _televisionGrid(
                        items,
                        constraints.maxWidth,
                        key: 'saved-$_tab',
                        saved: true,
                      );
                    }
                    final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
                    return GridView.builder(
                      padding: EdgeInsets.fromLTRB(padding, 0, padding, 20),
                      gridDelegate: dramaGridDelegate(
                        context,
                        constraints.maxWidth - 2 * padding,
                      ),
                      itemCount: items.length,
                      itemBuilder: (_, index) {
                        final drama = items[index];
                        final entry = widget.store.watched(drama.id);
                        return DramaTile(
                          drama: drama,
                          repository: widget.repository,
                          onTap: () => _openDrama(drama),
                          subtitle: entry == null
                              ? SourceSite.byId(drama.source).name
                              : '看到第 ${entry.episode} 集 · ${formatPosition(entry.position)}',
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    required String key,
    ScrollController? controller,
    Widget? footer,
    bool saved = false,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: ValueKey('tv-grid-$key'),
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      itemBuilder: (_, index, node, onFocus) {
        final drama = items[index];
        final entry = widget.store.watched(drama.id);
        return DramaTile(
          key: ValueKey(drama.id),
          drama: drama,
          repository: widget.repository,
          focusNode: node,
          onFocus: onFocus,
          onTap: () => _openDrama(drama),
          subtitle: !saved
              ? null
              : entry == null
              ? SourceSite.byId(drama.source).name
              : '第 ${entry.episode} 集 · ${formatPosition(entry.position)}',
        );
      },
    );
  }
}
