import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'app_bottom_navigation.dart';
import 'core_bridge.dart';
import 'catalog_filters.dart';
import 'catalog_browser.dart';
import 'rankings_screen.dart';
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
  int _generation = 0;
  int _tab = 0;
  String _submittedQuery = '';
  bool _failedMore = false;
  final _categorySelections = <String, String>{};
  late final CatalogBrowser _browser;
  bool _searchVisible = false;
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;

  List<SourceGroup> get _sourceGroups =>
      SourceGroup.fromSources(widget.store.sources);
  SourceGroup get _group =>
      _sourceGroups.where((group) => group.id == _source.groupId).firstOrNull ??
      SourceGroup(_source.groupId, _source.groupName, [_source]);
  String get _category => _categorySelections[_group.id] ?? '';
  List<CatalogCategory> get _categories => _browser.categories(_group);

  Future<void> _loadCategories({bool force = false}) async {
    final generation = ++_categoryGeneration;
    final group = _group;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    final error = await _browser.loadCategories(group, force: force);
    if (!mounted ||
        generation != _categoryGeneration ||
        group.id != _group.id) {
      return;
    }
    setState(() {
      _categoriesLoading = false;
      _categoriesError = error;
    });
    if (_category.isNotEmpty &&
        !_categories.any((entry) => entry.id == _category)) {
      _changeCategory('');
    }
  }

  Future<void> _refreshCatalog() async {
    await _loadCategories(force: true);
    if (mounted) await _load(force: true);
  }

  void _changeGroup(SourceGroup group) {
    if (_source.groupId != group.id) _changeSource(group.sources.first);
  }

  void _changeCategory(String category) {
    if (_category == category) return;
    _debounce?.cancel();
    setState(() {
      _categorySelections[_group.id] = category;
      if (_source.onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  void _swipeCategory(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 240) return;
    final categories = _categories;
    final index = categories.indexWhere((entry) => entry.id == _category);
    final next = index + (velocity < 0 ? 1 : -1);
    if (next >= 0 && next < categories.length) {
      _changeCategory(categories[next].id);
    }
  }

  void _toggleSearch() {
    if (AppLayout.isTelevision(context)) {
      _televisionSearch();
      return;
    }
    final hadQuery = _search.text.isNotEmpty;
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) _search.clear();
    });
    if (!_searchVisible && hadQuery) _searchChanged('');
  }

  void _openRankings() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialGroup: _group.id,
        ),
      ),
    );
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
    if (!mounted) return;
    await _loadCategories();
    if (mounted && (!_source.onlineSearch || _submittedQuery.isEmpty)) {
      await _load(useCache: true);
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
    _browser = CatalogBrowser(widget.repository);
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
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final group = _group;
    final query = _source.onlineSearch ? _search.text.trim() : '';
    setState(() {
      _error = null;
      if (query.isNotEmpty) _categorySelections[group.id] = '';
      _failedMore = false;
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery) _items = [];
      }
    });
    void accept(CatalogPage result, {bool cached = false}) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = result.items;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        _loading = cached && !result.fresh;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
    }

    try {
      final result = await _browser.load(
        group,
        category: _category,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        onCached: (result) => accept(result, cached: true),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
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
      _items = [];
      _hasMore = true;
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
          categoryName(drama.category) != _category.substring(6)) {
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
            titleSpacing: 12,
            title: _tab == 0
                ? PopupMenuButton<SourceGroup>(
                    key: const ValueKey('source-switch'),
                    tooltip: '切换站源',
                    enabled: _sourceGroups.length > 1,
                    onSelected: _changeGroup,
                    itemBuilder: (_) => [
                      for (final group in _sourceGroups)
                        PopupMenuItem(
                          value: group,
                          child: Row(
                            children: [
                              Expanded(child: Text(group.name)),
                              if (group.id == _group.id)
                                const Icon(Icons.check_rounded, size: 20),
                            ],
                          ),
                        ),
                    ],
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              _group.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (_sourceGroups.length > 1)
                            const Icon(Icons.expand_more_rounded),
                        ],
                      ),
                    ),
                  )
                : const Text(appName),
            actions: [
              if (_tab == 0) ...[
                IconButton(
                  key: const ValueKey('open-rankings'),
                  tooltip: '榜单',
                  icon: const Icon(Icons.leaderboard_outlined),
                  onPressed: widget.store.sources.isEmpty
                      ? null
                      : _openRankings,
                ),
                IconButton(
                  key: const ValueKey('toggle-search'),
                  tooltip: _searchVisible ? '收起搜索' : '搜索',
                  icon: Icon(
                    _searchVisible
                        ? Icons.search_off_rounded
                        : Icons.search_rounded,
                  ),
                  onPressed: _toggleSearch,
                ),
              ],
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
        if (_searchVisible && !television)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: SearchInput(
              key: ValueKey('search-${_group.id}'),
              controller: _search,
              autofocus: true,
              hint: _source.onlineSearch ? '搜索红果短剧' : '筛选本机已更新剧库',
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
          key: ValueKey('filters-${_group.id}'),
          categories: _categories,
          category: _category,
          error: _categoriesError,
          onCategory: _changeCategory,
          onRetry: () => _loadCategories(force: true),
          trailing: _supportsVipFilter
              ? IconButton(
                  tooltip: widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
                  onPressed: () =>
                      widget.store.setHideVip(!widget.store.hideVip),
                  icon: Icon(
                    widget.store.hideVip
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                )
              : _category.startsWith('local:')
              ? const Tooltip(
                  message: '筛选本机已更新剧库；更新站源可获取更多分类和剧集',
                  child: Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: Icon(Icons.info_outline, size: 18),
                  ),
                )
              : null,
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
          child: GestureDetector(
            onHorizontalDragEnd: television ? null : _swipeCategory,
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
                          key:
                              'catalog-${_group.id}-$_category-$_submittedQuery',
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
