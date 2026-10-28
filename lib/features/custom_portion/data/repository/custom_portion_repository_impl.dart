import 'package:opennutritracker/core/data/dbo/custom_portion_dbo.dart';
import 'package:opennutritracker/core/utils/id_generator.dart';
import 'package:opennutritracker/features/custom_portion/data/data_source/custom_portion_data_source.dart';
import 'package:opennutritracker/features/custom_portion/domain/entity/custom_portion_entity.dart';
import 'package:opennutritracker/features/custom_portion/domain/repository/custom_portion_repository.dart';

class CustomPortionRepositoryImpl implements CustomPortionRepository {
  final CustomPortionDataSource _dataSource;

  CustomPortionRepositoryImpl(this._dataSource);

  @override
  Future<List<CustomPortionEntity>> getForFood(String foodKey) async =>
      _dataSource
          .getForFood(foodKey)
          .map(CustomPortionEntity.fromDBO)
          .toList(growable: false);

  @override
  Future<CustomPortionEntity> add({
    required String foodKey,
    required String label,
    required double gramWeight,
    required String unit,
  }) async {
    final name = label.trim();
    final sameName = _dataSource
        .getForFood(foodKey)
        .where((portion) => _sameName(portion.label, name))
        .firstOrNull;
    final saved = CustomPortionDBO(
      id: sameName?.id ?? IdGenerator.getUniqueID(),
      foodKey: foodKey,
      label: name,
      gramWeight: gramWeight,
      unit: unit,
      createdAt: sameName?.createdAt ?? DateTime.now(),
    );
    await _dataSource.put(saved);
    return CustomPortionEntity.fromDBO(saved);
  }

  @override
  Future<void> delete(String id) => _dataSource.delete(id);

  @override
  Future<List<CustomPortionDBO>> getAllDBOs() async => _dataSource.getAll();

  @override
  Future<void> upsertAllDBOs(List<CustomPortionDBO> portions) {
    // The last row for an id wins, as `Box.putAll` resolves it.
    return _dataSource.putAll([
      for (final portion in portions)
        if (portion.id.trim().isNotEmpty &&
            portion.foodKey.trim().isNotEmpty &&
            portion.label.trim().isNotEmpty &&
            portion.gramWeight.isFinite &&
            portion.gramWeight > 0)
          portion,
    ]);
  }

  static bool _sameName(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();
}
