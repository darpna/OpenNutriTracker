import 'package:hive_ce/hive.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/data/dbo/custom_portion_dbo.dart';
import 'package:opennutritracker/core/utils/hive_db_provider.dart';

/// The shared Hive box of [CustomPortionDBO]s, keyed by [CustomPortionDBO.id].
class CustomPortionDataSource {
  final log = Logger('CustomPortionDataSource');
  final HiveDBProvider _db;

  CustomPortionDataSource(this._db);

  Box<CustomPortionDBO> get _box => _db.customPortionBox;

  /// Oldest first, so a serving keeps its place in a food's list.
  List<CustomPortionDBO> getForFood(String foodKey) =>
      _box.values.where((portion) => portion.foodKey == foodKey).toList()
        ..sort(_oldestFirst);

  List<CustomPortionDBO> getAll() => _box.values.toList()..sort(_oldestFirst);

  Future<void> put(CustomPortionDBO portion) async {
    log.fine('Saving custom portion ${portion.id} for ${portion.foodKey}');
    await _box.put(portion.id, portion);
  }

  Future<void> putAll(List<CustomPortionDBO> portions) async {
    log.fine('Saving ${portions.length} custom portions');
    await _box.putAll({for (final portion in portions) portion.id: portion});
  }

  Future<void> delete(String id) async {
    log.fine('Deleting custom portion $id');
    await _box.delete(id);
  }

  static int _oldestFirst(CustomPortionDBO a, CustomPortionDBO b) {
    final byTime = a.createdAt.compareTo(b.createdAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }
}
