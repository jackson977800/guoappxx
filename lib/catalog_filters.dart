import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'models.dart';
import 'remote_widgets.dart';

class CatalogFilters extends StatelessWidget {
  const CatalogFilters({
    super.key,
    required this.groups,
    required this.source,
    required this.categories,
    required this.category,
    required this.loading,
    required this.onGroup,
    required this.onSource,
    required this.onCategory,
    required this.onRetry,
    this.error,
  });

  final List<SourceGroup> groups;
  final SourceSite source;
  final List<CatalogCategory> categories;
  final String category;
  final bool loading;
  final String? error;
  final ValueChanged<SourceGroup> onGroup;
  final ValueChanged<SourceSite> onSource;
  final ValueChanged<String> onCategory;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final entries =
        groups
            .where((group) => group.id == source.groupId)
            .firstOrNull
            ?.sources ??
        const <SourceSite>[];
    final selected =
        categories.where((entry) => entry.id == category).firstOrNull ??
        CatalogCategory.all;
    Widget choice(
      String key,
      String label,
      bool selected,
      VoidCallback select,
    ) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: television
          ? RemoteButton(
              key: ValueKey('tv-$key'),
              label: label,
              selected: selected,
              onPressed: select,
            )
          : ChoiceChip(
              key: ValueKey(key),
              label: Text(label),
              selected: selected,
              showCheckmark: false,
              onSelected: (_) => select(),
            ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final group in groups)
                  choice(
                    'source-${group.id}',
                    group.name,
                    group.id == source.groupId,
                    () => onGroup(group),
                  ),
              ],
            ),
          ),
          if (source.groupId == 'huangguo') ...[
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: Text('入口'),
                  ),
                  for (final entry in entries)
                    choice(
                      'entry-${entry.id}',
                      entry.entryName,
                      entry.id == source.id,
                      () => onSource(entry),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: '内容分类',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('catalog-category'),
                      value: selected.id,
                      isExpanded: true,
                      items: [
                        for (final entry in categories)
                          DropdownMenuItem(
                            value: entry.id,
                            child: Text(
                              entry.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) onCategory(value);
                      },
                    ),
                  ),
                ),
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (error != null)
                IconButton(
                  tooltip: '重新加载分类',
                  onPressed: onRetry,
                  icon: Icon(
                    Icons.refresh_rounded,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
          ),
          if (selected.local)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '筛选已加载的剧集',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '分类加载失败，可点击重试',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
