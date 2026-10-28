import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:opennutritracker/core/data/dbo/custom_portion_dbo.dart';
import 'package:opennutritracker/core/data/dbo/favourite_meal_dbo.dart';
import 'package:opennutritracker/core/data/dbo/meal_dbo.dart';
import 'package:opennutritracker/core/data/repository/favourite_meal_repository.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/custom_portion/data/data_source/custom_portion_data_source.dart';
import 'package:opennutritracker/features/custom_portion/data/repository/custom_portion_repository_impl.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/add_custom_portion_usecase.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/delete_custom_portion_usecase.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/get_custom_portions_usecase.dart';

import '../helpers/fake_hive_db_provider.dart';
import '../helpers/hive_test_setup.dart';

MealEntity _meal({
  String? code = '3017620422003',
  String name = 'Hazelnut spread',
  MealSourceEntity source = MealSourceEntity.off,
  String unit = 'g',
}) => MealEntity(
  code: code,
  name: name,
  url: null,
  mealQuantity: '100',
  mealUnit: unit,
  servingQuantity: null,
  servingUnit: null,
  servingSize: null,
  nutriments: MealNutrimentsEntity.empty(),
  source: source,
);

void main() {
  late Directory tempDir;
  late Box<CustomPortionDBO> box;
  late CustomPortionRepositoryImpl repository;
  late GetCustomPortionsUsecase get;
  late AddCustomPortionUsecase add;
  late DeleteCustomPortionUsecase delete;

  setUpAll(() {
    registerHiveAdaptersOnce();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ont_custom_portion_');
    Hive.init(tempDir.path);
    box = await Hive.openBox<CustomPortionDBO>('custom_portions');
    repository = CustomPortionRepositoryImpl(
      CustomPortionDataSource(FakeHiveDBProvider(customPortionBox: box)),
    );
    get = GetCustomPortionsUsecase(repository);
    add = AddCustomPortionUsecase(repository);
    delete = DeleteCustomPortionUsecase(repository);
  });

  tearDown(() async {
    await box.close();
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('add, get and delete round trip through the box', () async {
    final meal = _meal();
    expect(await get.getCustomPortions(meal), isEmpty);

    final bowl = await add.addCustomPortion(
      meal,
      label: '1 bowl',
      gramWeight: 250,
    );
    final roti = await add.addCustomPortion(
      meal,
      label: '1 roti',
      gramWeight: 40,
    );

    final saved = await get.getCustomPortions(meal);
    expect(saved.map((p) => (p.label, p.gramWeight, p.unit)), [
      ('1 bowl', 250.0, 'g'),
      ('1 roti', 40.0, 'g'),
    ]);

    await delete.deleteCustomPortion(bowl.id);
    expect((await get.getCustomPortions(meal)).map((p) => p.id), [roti.id]);
    expect(box.length, 1);
  });

  test('a serving survives closing and reopening the box', () async {
    final meal = _meal();
    await add.addCustomPortion(meal, label: '1 bowl', gramWeight: 250);
    await box.close();

    box = await Hive.openBox<CustomPortionDBO>('custom_portions');
    final reopened = GetCustomPortionsUsecase(
      CustomPortionRepositoryImpl(
        CustomPortionDataSource(FakeHiveDBProvider(customPortionBox: box)),
      ),
    );
    expect((await reopened.getCustomPortions(meal)).single.label, '1 bowl');
  });

  test('a food is found by the key Favourites uses, and only by it', () async {
    final meal = _meal();
    final saved = await add.addCustomPortion(
      meal,
      label: '1 bowl',
      gramWeight: 250,
    );

    expect(saved.foodKey, FavouriteMealRepository.keyOf(meal));
    expect(
      saved.foodKey,
      FavouriteMealDBO.keyFor(MealSourceDBO.off, '3017620422003', 'x'),
    );
    // Same code from another source is another food.
    expect(
      await get.getCustomPortions(_meal(source: MealSourceEntity.fdc)),
      isEmpty,
    );
    // A search result and the detail record of the same food share servings:
    // the key does not look at the name.
    expect(await get.getCustomPortions(_meal(name: 'Renamed')), hasLength(1));
  });

  test('a food without a code falls back to its name, as favourites do', () async {
    final meal = _meal(code: null, name: 'Dal', source: MealSourceEntity.custom);
    await add.addCustomPortion(meal, label: '1 bowl', gramWeight: 200);

    expect(await get.getCustomPortions(meal), hasLength(1));
    expect(
      await get.getCustomPortions(
        _meal(code: null, name: 'Rice', source: MealSourceEntity.custom),
      ),
      isEmpty,
    );
  });

  test('saving a name the food already has updates it instead of listing it twice', () async {
    final meal = _meal();
    final first = await add.addCustomPortion(
      meal,
      label: '1 bowl',
      gramWeight: 250,
    );
    final second = await add.addCustomPortion(
      meal,
      label: '  1 BOWL ',
      gramWeight: 300,
    );

    expect(second.id, first.id);
    final saved = await get.getCustomPortions(meal);
    expect(saved, hasLength(1));
    expect(saved.single.gramWeight, 300);
    expect(saved.single.label, '1 BOWL');
  });

  test('a food measured only in millilitres stores its servings in ml', () async {
    final saved = await add.addCustomPortion(
      _meal(unit: 'ml'),
      label: '1 glass',
      gramWeight: 200,
    );
    expect(saved.unit, 'ml');
    expect(customPortionUnitFor(_meal()), 'g');
  });

  test('a name or weight the dialog would refuse is not stored', () async {
    final meal = _meal();
    for (final (label, weight) in [
      ('', 100.0),
      ('   ', 100.0),
      ('1 bowl', 0.0),
      ('1 bowl', -5.0),
      ('1 bowl', double.nan),
      ('1 bowl', double.infinity),
      ('1 bowl', 10001.0),
      ('x' * 41, 100.0),
    ]) {
      expect(
        () => add.addCustomPortion(meal, label: label, gramWeight: weight),
        throwsArgumentError,
        reason: '"$label" = $weight',
      );
    }
    expect(box, isEmpty);
  });

  test('upsertAllDBOs replaces by id and skips rows that cannot scale', () async {
    final now = DateTime(2026, 10, 1);
    CustomPortionDBO row(String id, String label, double grams, {String food = 'off:1'}) =>
        CustomPortionDBO(
          id: id,
          foodKey: food,
          label: label,
          gramWeight: grams,
          createdAt: now,
        );

    await repository.upsertAllDBOs([row('a', '1 bowl', 250)]);
    await repository.upsertAllDBOs([
      row('a', '1 bowl', 300),
      row('b', '', 10),
      row('c', '1 cup', 0),
      row('d', '1 cup', double.nan),
      row('e', '1 cup', 100, food: ' '),
    ]);

    final all = await repository.getAllDBOs();
    expect(all.map((p) => (p.id, p.gramWeight)), [('a', 300.0)]);
  });
}
