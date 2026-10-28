import 'package:opennutritracker/core/data/dbo/custom_portion_dbo.dart';
import 'package:opennutritracker/features/custom_portion/domain/entity/custom_portion_entity.dart';
import 'package:opennutritracker/features/custom_portion/domain/repository/custom_portion_repository.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/add_custom_portion_usecase.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/delete_custom_portion_usecase.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/get_custom_portions_usecase.dart';

/// An in-memory [CustomPortionRepository] behind the three real use cases, so
/// bloc and widget tests exercise the validation and the food key without a
/// Hive box.
class FakeCustomPortions implements CustomPortionRepository {
  final _rows = <String, CustomPortionDBO>{};
  var _next = 0;

  late final getUsecase = GetCustomPortionsUsecase(this);
  late final addUsecase = AddCustomPortionUsecase(this);
  late final deleteUsecase = DeleteCustomPortionUsecase(this);

  List<CustomPortionDBO> get rows => _rows.values.toList();

  @override
  Future<List<CustomPortionEntity>> getForFood(String foodKey) async => [
    for (final row in _rows.values)
      if (row.foodKey == foodKey) CustomPortionEntity.fromDBO(row),
  ];

  @override
  Future<CustomPortionEntity> add({
    required String foodKey,
    required String label,
    required double gramWeight,
    required String unit,
  }) async {
    // Like the real repository: the same name on a food updates in place.
    final existing = _rows.values
        .where(
          (r) =>
              r.foodKey == foodKey &&
              r.label.toLowerCase() == label.trim().toLowerCase(),
        )
        .firstOrNull;
    final row = CustomPortionDBO(
      id: existing?.id ?? 'p${_next++}',
      foodKey: foodKey,
      label: label.trim(),
      gramWeight: gramWeight,
      unit: unit,
      createdAt:
          existing?.createdAt ??
          DateTime(2026, 10, 1).add(Duration(minutes: _next)),
    );
    _rows[row.id] = row;
    return CustomPortionEntity.fromDBO(row);
  }

  @override
  Future<void> delete(String id) async => _rows.remove(id);

  @override
  Future<List<CustomPortionDBO>> getAllDBOs() async => rows;

  @override
  Future<void> upsertAllDBOs(List<CustomPortionDBO> portions) async {
    for (final portion in portions) {
      _rows[portion.id] = portion;
    }
  }
}
