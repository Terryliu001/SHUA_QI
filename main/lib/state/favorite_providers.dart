import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/app/favorite/favorite_redo_paper_store.dart';
import 'package:shuaqi/app/favorite/favorite_stem_service.dart';
import 'package:shuaqi/app/favorite/favorite_store.dart';
import 'package:shuaqi/app/favorite/redo_attempt_store.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/redo_attempt.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/region_providers.dart';

/// 收藏夹用例入口（跨卷快照库）。
final Provider<FavoriteStore> favoriteStoreProvider =
    Provider<FavoriteStore>((Ref ref) {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      return FavoriteStore(
        db: deps.db,
        vault: deps.vault,
        layout: ref.watch(layoutStoreProvider),
      );
    });

/// 收藏题面图的按需高清重渲染（T8.3b，用户："点开后清晰一点"）。
final Provider<FavoriteStemService> favoriteStemServiceProvider =
    Provider<FavoriteStemService>((Ref ref) {
      return FavoriteStemService(vault: ref.watch(vaultProvider));
    });

/// 重刷答题纸配置（每道收藏一份 `favorites/<id>/paper.json`）。
final Provider<FavoriteRedoPaperStore> favoriteRedoPaperStoreProvider =
    Provider<FavoriteRedoPaperStore>((Ref ref) {
      return FavoriteRedoPaperStore(ref.watch(vaultProvider));
    });

/// 重刷 attempt 的文件读写与旧数据迁移。
final Provider<RedoAttemptStore> redoAttemptStoreProvider =
    Provider<RedoAttemptStore>((Ref ref) {
      return RedoAttemptStore(ref.watch(vaultProvider));
    });

/// 某道收藏的全部重刷记录（按更新时间倒序）。
final FutureProvider<List<RedoAttempt>> Function(String) redoAttemptsProvider =
    FutureProvider.family<List<RedoAttempt>, String>((Ref ref, String favoriteId) {
      return ref.watch(redoAttemptStoreProvider).list(favoriteId);
    });

/// 全部收藏，按最近更新倒序。收藏/取消收藏/改知识点后 `ref.invalidate` 刷新。
final FutureProvider<List<Favorite>> favoritesProvider =
    FutureProvider<List<Favorite>>((Ref ref) {
      return ref.watch(favoriteStoreProvider).list();
    });

/// 全部组卷（带成员数），按最近更新倒序。
final FutureProvider<List<FavoriteSet>> favoriteSetsProvider =
    FutureProvider<List<FavoriteSet>>((Ref ref) {
      return ref.watch(favoriteStoreProvider).listSets();
    });

/// 一份组卷的成员（收藏对象，顺序 = 卷内题序）。
final FutureProvider<List<Favorite>> Function(String) favoriteSetItemsProvider =
    FutureProvider.family<List<Favorite>, String>((Ref ref, String setId) {
      return ref.watch(favoriteStoreProvider).itemsOfSet(setId);
    });
