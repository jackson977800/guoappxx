import 'dart:async';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class CategoryRepository extends FixtureRepository {
  final categoryRequests = <String>[];
  Completer<CatalogPage>? pendingComic;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => source == 'huangguoai'
      ? const [
          CatalogCategory.all,
          CatalogCategory('ai-duanju', 'AI 短剧'),
          CatalogCategory('ai-manju', 'AI 漫剧'),
        ]
      : const [CatalogCategory.all];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    categoryRequests.add('$source|$category|$page');
    if (category == 'ai-manju' && pendingComic != null) {
      return pendingComic!.future;
    }
    return CatalogPage([
      Drama(
        id: '$source:$category',
        source: source,
        title: '$source · ${category.isEmpty ? '全部' : category}',
      ),
    ]);
  }
}

void main() {
  testWidgets(
    'Huangguo entries share one group and category changes reject stale results',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setSource('huangguoai');
      final repository = CategoryRepository();
      await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('source-huangguo')), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '黄果 AI'), findsNothing);
      expect(
        find.byKey(const ValueKey('entry-huangguo-video')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('entry-cloudfront')), findsOneWidget);

      Future<void> choose(String name) async {
        await tester.tap(find.byKey(const ValueKey('catalog-category')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(name).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      final pending = Completer<CatalogPage>();
      repository.pendingComic = pending;
      await choose('AI 漫剧');
      expect(repository.categoryRequests.last, 'huangguoai|ai-manju|1');
      await choose('AI 短剧');
      await tester.pumpAndSettle();
      pending.complete(
        CatalogPage(const [
          Drama(id: 'huangguoai:stale', source: 'huangguoai', title: '过期分类结果'),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('过期分类结果'), findsNothing);
      expect(find.text('huangguoai · ai-duanju'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('entry-cloudfront')));
      await tester.pumpAndSettle();
      expect(repository.categoryRequests.last, 'cloudfront||1');
      await tester.tap(find.byKey(const ValueKey('entry-huangguoai')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('catalog-category')),
            )
            .value,
        'ai-duanju',
      );
      expect(repository.categoryRequests.last, 'huangguoai|ai-duanju|1');
      expect(tester.takeException(), isNull);
    },
    skip: !allSourcesEnabled,
  );
}
