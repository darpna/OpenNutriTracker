import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_portion_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_photo_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_text_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/search_products_usecase.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/add_meal/util/portion_unit.dart';
import 'package:opennutritracker/features/meal_detail/util/meal_quantity_converter.dart';

import '../../helpers/fake_custom_portions.dart';

MealEntity _meal(
  String name, {
  List<MealPortionEntity> portions = const [],
  double? servingQuantity,
}) => MealEntity(
  code: name,
  name: name,
  url: null,
  mealQuantity: null,
  mealUnit: 'g',
  servingQuantity: servingQuantity,
  servingUnit: servingQuantity == null ? null : 'g',
  servingSize: null,
  portions: portions,
  source: MealSourceEntity.off,
  nutriments: MealNutrimentsEntity.empty(),
);

class _FakeSearch implements SearchProductsUseCase {
  _FakeSearch(this.results);

  final Map<String, List<MealEntity>> results;

  @override
  Future<SearchProductsResult> searchOFFProductsByString(
    String searchString, {
    bool skipRemote = false,
  }) async => SearchProductsResult(
    meals: results[searchString] ?? const [],
    remoteSourceEmpty: false,
  );

  @override
  Future<SearchProductsResult> searchFDCFoodByString(
    String searchString, {
    bool skipRemote = false,
    bool forResolution = false,
  }) async => const SearchProductsResult(meals: [], remoteSourceEmpty: false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyStorage implements FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BulkAddBloc _bloc(
  Map<String, List<MealEntity>> results,
  FakeCustomPortions portions,
) {
  ReadMealTextUseCase reader() => ReadMealTextUseCase(
    AiCredentialStorage(_EmptyStorage()),
    (_) => throw StateError('must not be built without a key'),
  );
  return BulkAddBloc(
    ResolveParsedMealsUseCase(_FakeSearch(results)),
    reader(),
    ReadMealPhotoUseCase(
      AiCredentialStorage(_EmptyStorage()),
      (_) => throw StateError('must not be built without a key'),
    ),
    getCustomPortions: portions.getUsecase,
    addCustomPortion: portions.addUsecase,
    deleteCustomPortion: portions.deleteUsecase,
  );
}

Future<BulkAddLoadedState> _parse(BulkAddBloc bloc, String text) async {
  bloc.add(ParseBulkTextEvent(text: text, usesImperialUnits: false));
  return await bloc.stream.firstWhere((s) => s is BulkAddLoadedState)
      as BulkAddLoadedState;
}

Future<BulkAddLoadedState> _next(BulkAddBloc bloc) async =>
    await bloc.stream.firstWhere((s) => s is BulkAddLoadedState)
        as BulkAddLoadedState;

void main() {
  late FakeCustomPortions portions;

  setUp(() => portions = FakeCustomPortions());

  test('a food the user has servings for arrives with them', () async {
    await portions.addUsecase.addCustomPortion(
      _meal('Dal'),
      label: '1 bowl',
      gramWeight: 250,
    );
    final bloc = _bloc({
      'dal': [_meal('Dal')],
    }, portions);

    final state = await _parse(bloc, '2 dal');

    final row = state.rows.single;
    expect(row.meal!.portions.map((p) => p.label), ['1 bowl']);
    expect(row.allowedUnits.where(isPortionUnit), ['serving']);
    expect(convertQuantityToBaseUnit(2, 'serving', row.meal!), 500);
    await bloc.close();
  });

  test('a food without any is left exactly as it was', () async {
    final bloc = _bloc({
      'dal': [_meal('Dal')],
    }, portions);

    final state = await _parse(bloc, '2 dal');

    expect(state.rows.single.meal!.portions, isEmpty);
    expect(state.rows.single.allowedUnits.where(isPortionUnit), isEmpty);
    await bloc.close();
  });

  test('without the use cases nothing is offered', () async {
    final bloc = BulkAddBloc(
      ResolveParsedMealsUseCase(
        _FakeSearch({
          'dal': [_meal('Dal')],
        }),
      ),
      ReadMealTextUseCase(
        AiCredentialStorage(_EmptyStorage()),
        (_) => throw StateError('unused'),
      ),
      ReadMealPhotoUseCase(
        AiCredentialStorage(_EmptyStorage()),
        (_) => throw StateError('unused'),
      ),
    );
    expect(bloc.supportsCustomPortions, isFalse);
    await bloc.close();
  });

  test('adding a serving to a row selects it with an amount of 1', () async {
    final bloc = _bloc({
      'dal': [_meal('Dal')],
    }, portions);
    await _parse(bloc, '2 dal');

    bloc.add(const AddRowCustomPortionEvent(0, '1 bowl', 250));
    final state = await _next(bloc);

    final row = state.rows.single;
    expect(row.amountText, '1');
    expect(row.unit, 'serving');
    expect(row.unitChosenByUser, isTrue);
    expect(convertQuantityToBaseUnit(1, row.unit, row.meal!), 250);
    expect(portions.rows.single.foodKey, 'off:Dal');
    await bloc.close();
  });

  test('a second serving lands after the database portions', () async {
    const cup = MealPortionEntity(
      label: '1 cup',
      gramWeight: 244,
      localized: false,
    );
    final bloc = _bloc({
      'milk': [
        _meal('Milk', portions: [cup]),
      ],
    }, portions);
    await _parse(bloc, 'milk');

    bloc.add(const AddRowCustomPortionEvent(0, '1 glass', 200));
    final state = await _next(bloc);

    final row = state.rows.single;
    expect(row.meal!.portions.map((p) => p.label), ['1 cup', '1 glass']);
    expect(row.unit, 'serving#1');
    expect(convertQuantityToBaseUnit(1, row.unit, row.meal!), 200);
    await bloc.close();
  });

  test('deleting the serving a row counts in puts the row back on its default', () async {
    await portions.addUsecase.addCustomPortion(
      _meal('Dal'),
      label: '1 bowl',
      gramWeight: 250,
    );
    final bloc = _bloc({
      'dal': [_meal('Dal')],
    }, portions);
    final loaded = await _parse(bloc, 'dal');
    final id = loaded.rows.single.meal!.portions.single.customPortionId!;
    bloc.add(const ChangeRowUnitEvent(0, 'serving'));
    await _next(bloc);

    bloc.add(DeleteRowCustomPortionEvent(0, id));
    final state = await _next(bloc);

    expect(portions.rows, isEmpty);
    expect(state.rows.single.meal!.portions, isEmpty);
    expect(state.rows.single.effectiveUnit, isNot('serving'));
    await bloc.close();
  });

  test('a food with a serving of its own keeps `serving` meaning it', () async {
    final bloc = _bloc({
      'bar': [_meal('Bar', servingQuantity: 30)],
    }, portions);
    await _parse(bloc, '1 bar');

    bloc.add(const AddRowCustomPortionEvent(0, '1 scoop', 45));
    final state = await _next(bloc);

    final meal = state.rows.single.meal!;
    expect(convertQuantityToBaseUnit(2, 'serving', meal), 60);
    expect(convertQuantityToBaseUnit(2, 'serving#1', meal), 90);
    await bloc.close();
  });
}
