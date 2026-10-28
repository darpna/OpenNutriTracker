import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:opennutritracker/core/data/data_source/remote_search_cache_data_source.dart';
import 'package:opennutritracker/core/data/dbo/meal_dbo.dart';
import 'package:opennutritracker/core/domain/entity/app_theme_entity.dart';
import 'package:opennutritracker/core/domain/entity/config_entity.dart';
import 'package:opennutritracker/core/domain/entity/intake_entity.dart';
import 'package:opennutritracker/core/domain/entity/intake_type_entity.dart';
import 'package:opennutritracker/core/domain/entity/tracked_day_entity.dart';
import 'package:opennutritracker/core/domain/usecase/add_intake_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/add_tracked_day_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_intake_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_kcal_goal_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_macro_goal_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_tracked_day_usecase.dart';
import 'package:opennutritracker/core/utils/energy_unit_provider.dart';
import 'package:opennutritracker/core/utils/navigation_options.dart';
import 'package:opennutritracker/features/add_meal/data/repository/products_repository.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/favourite_toggle_bloc.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/calendar_day_bloc.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/diary_bloc.dart';
import 'package:opennutritracker/features/home/presentation/bloc/home_bloc.dart';
import 'package:opennutritracker/features/meal_detail/meal_detail_screen.dart';
import 'package:opennutritracker/features/meal_detail/presentation/bloc/meal_detail_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';
import 'package:provider/provider.dart';

import '../../helpers/fake_custom_portions.dart';
import '../../helpers/fake_favourites.dart';
import '../../helpers/test_l10n.dart';

// Drives the real [MealDetailScreen] through the custom-serving flow: the
// "Add serving" chip and picker entry, the dialog, the new serving being
// selected with an amount of 1, and the serving coming back on the next visit.

const _nutriments = MealNutrimentsEntity(
  energyKcal100: 100,
  carbohydrates100: 10,
  fat100: 5,
  proteins100: 5,
  sugars100: 2,
  saturatedFat100: 1,
  fiber100: 1,
);

/// No portions, no serving values: the case the chip is for.
MealEntity _plainFood() => MealEntity(
  code: 'dal-1',
  name: 'Dal',
  url: null,
  mealQuantity: null,
  mealUnit: 'g',
  servingQuantity: null,
  servingUnit: null,
  servingSize: null,
  nutriments: _nutriments,
  source: MealSourceEntity.custom,
);

MealEntity _foodWithServing() => MealEntity(
  code: 'bar-1',
  name: 'Bar',
  url: null,
  mealQuantity: null,
  mealUnit: 'g',
  servingQuantity: 30,
  servingUnit: 'g',
  servingSize: '30 g',
  nutriments: _nutriments,
  source: MealSourceEntity.custom,
);

void main() {
  final getIt = GetIt.instance;
  late MealDetailBloc bloc;
  late FakeCustomPortions portions;
  late _FakeAddIntakeUsecase intakes;

  setUp(() {
    portions = FakeCustomPortions();
    intakes = _FakeAddIntakeUsecase();
    getIt.registerFactory<MealDetailBloc>(
      () => bloc = MealDetailBloc(
        intakes,
        _FakeAddTrackedDayUsecase(),
        _FakeGetKcalGoalUsecase(),
        _FakeGetMacroGoalUsecase(),
        _FakeGetTrackedDayUsecase(),
        _FakeProductsRepository(),
        _FakeRemoteSearchCacheDataSource(),
        getCustomPortions: portions.getUsecase,
        addCustomPortion: portions.addUsecase,
        deleteCustomPortion: portions.deleteUsecase,
      ),
    );
    getIt.registerLazySingleton<GetConfigUsecase>(_FakeGetConfigUsecase.new);
    getIt.registerLazySingleton<GetIntakeUsecase>(_FakeGetIntakeUsecase.new);
    getIt.registerLazySingleton<CacheManager>(_FakeCacheManager.new);
    final favourites = FakeFavourites();
    getIt.registerFactory<FavouriteToggleBloc>(
      () => FavouriteToggleBloc(favourites.get, favourites.toggle),
    );
    getIt.registerLazySingleton<HomeBloc>(_FakeHomeBloc.new);
    getIt.registerLazySingleton<DiaryBloc>(_FakeDiaryBloc.new);
    getIt.registerLazySingleton<CalendarDayBloc>(_FakeCalendarDayBloc.new);
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<void> pumpMealDetail(WidgetTester tester, MealEntity meal) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Route<void> routeFor(RouteSettings settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => const MealDetailScreen(),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<EnergyUnitProvider>(
        create: (_) => EnergyUnitProvider(),
        child: MaterialApp(
          localizationsDelegates: const [S.delegate],
          supportedLocales: S.supportedLocales,
          initialRoute: NavigationOptions.mealDetailRoute,
          onGenerateInitialRoutes: (_) => [
            routeFor(
              RouteSettings(
                name: NavigationOptions.mealDetailRoute,
                arguments: MealDetailScreenArguments(
                  meal,
                  IntakeTypeEntity.breakfast,
                  DateTime(2026, 9, 14),
                  false,
                ),
              ),
            ),
          ],
          onGenerateRoute: routeFor,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder identified(String id) => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.identifier == id,
  );

  Finder addServingChip() => identified('meal-detail-chip-add-serving');

  Future<void> addServingThroughDialog(
    WidgetTester tester, {
    String name = '1 bowl',
    String grams = '250',
  }) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, l10nEn.customPortionNameLabel),
      name,
    );
    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        l10nEn.customPortionWeightLabel(l10nEn.gramUnit),
      ),
      grams,
    );
    await tester.tap(find.text(l10nEn.buttonSaveLabel));
    await tester.pumpAndSettle();
  }

  Future<void> openUnitPicker(WidgetTester tester) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
  }

  String quantityText(WidgetTester tester) => tester
      .widget<TextFormField>(find.byType(TextFormField).first)
      .controller!
      .text;

  group('a food with no portions and no serving', () {
    testWidgets('offers an Add serving chip', (tester) async {
      await pumpMealDetail(tester, _plainFood());
      expect(addServingChip(), findsOneWidget);
    });

    testWidgets('saving selects the new serving with an amount of 1, in grams', (
      tester,
    ) async {
      await pumpMealDetail(tester, _plainFood());
      expect(bloc.state.selectedUnit, 'g');
      expect(bloc.state.totalQuantityConverted, '100.0');

      await tester.tap(addServingChip());
      await tester.pumpAndSettle();
      await addServingThroughDialog(tester);

      expect(find.text(l10nEn.customPortionNameRequired), findsNothing);
      expect(bloc.state.selectedUnit, 'serving');
      expect(quantityText(tester), '1');
      expect(bloc.state.totalQuantityConverted, '250.0');
      expect(bloc.state.totalKcal, 250);
      expect(portions.rows.single.label, '1 bowl');
      expect(portions.rows.single.foodKey, 'custom:dal-1');

      // The serving is now the food's portion, so the chip has done its job.
      expect(addServingChip(), findsNothing);
    });

    testWidgets('the amount keeps following the serving as it is edited', (
      tester,
    ) async {
      await pumpMealDetail(tester, _plainFood());
      await tester.tap(addServingChip());
      await tester.pumpAndSettle();
      await addServingThroughDialog(tester);

      await tester.enterText(find.byType(TextFormField).first, '2');
      await tester.pumpAndSettle();

      expect(bloc.state.selectedUnit, 'serving');
      expect(bloc.state.totalQuantityConverted, '500.0');
    });

    testWidgets('an invalid serving saves nothing and changes nothing', (
      tester,
    ) async {
      await pumpMealDetail(tester, _plainFood());
      await tester.tap(addServingChip());
      await tester.pumpAndSettle();
      await addServingThroughDialog(tester, name: '', grams: '0');

      expect(find.text(l10nEn.customPortionNameRequired), findsOneWidget);
      expect(portions.rows, isEmpty);
      expect(bloc.state.selectedUnit, 'g');
    });

    testWidgets('logging it stores grams under the plain serving unit', (
      tester,
    ) async {
      await pumpMealDetail(tester, _plainFood());
      await tester.tap(addServingChip());
      await tester.pumpAndSettle();
      await addServingThroughDialog(tester);

      await tester.tap(identified('meal-detail-add'));
      await tester.pumpAndSettle();

      final intake = intakes.logged.single;
      expect(intake.unit, 'serving');
      expect(intake.amount, 250);
      // The meal snapshot written is the one it always was: portions are
      // not part of the stored meal.
      expect(
        jsonEncode(MealDBO.fromMealEntity(intake.meal)),
        jsonEncode(MealDBO.fromMealEntity(_plainFood())),
      );
    });
  });

  group('a food that has a serving', () {
    testWidgets('has no chip, but the picker still offers Add serving', (
      tester,
    ) async {
      await pumpMealDetail(tester, _foodWithServing());
      expect(addServingChip(), findsNothing);

      await openUnitPicker(tester);
      await tester.tap(find.text(l10nEn.customPortionAddAction).last);
      await tester.pumpAndSettle();
      await addServingThroughDialog(tester, name: '1 scoop', grams: '45');

      // The food's own serving keeps `serving`; the new one follows it.
      expect(bloc.state.selectedUnit, 'serving#1');
      expect(bloc.state.totalQuantityConverted, '45.0');

      bloc.add(
        UpdateKcalEvent(
          meal: _foodWithServing(),
          totalQuantity: '1',
          selectedUnit: 'serving',
        ),
      );
      await tester.pumpAndSettle();
      expect(bloc.state.totalQuantityConverted, '30.0');
    });
  });

  group('the next time the food is opened', () {
    Future<void> seedBowl() => portions.addUsecase.addCustomPortion(
      _plainFood(),
      label: '1 bowl',
      gramWeight: 250,
    );

    testWidgets('its serving is in the picker, marked as the user\'s own', (
      tester,
    ) async {
      await seedBowl();
      await pumpMealDetail(tester, _plainFood());
      expect(addServingChip(), findsNothing);

      await openUnitPicker(tester);
      expect(find.text('1 bowl'), findsWidgets);
      expect(find.byIcon(Icons.person_outline_rounded), findsWidgets);

      await tester.tap(find.text('1 bowl').last);
      await tester.pumpAndSettle();
      expect(bloc.state.selectedUnit, 'serving');
      expect(bloc.state.totalQuantityConverted, '25000.0');
    });

    testWidgets('saving an identical serving selects the existing one', (
      tester,
    ) async {
      await seedBowl();
      await pumpMealDetail(tester, _plainFood());

      Future<void> saveBowlAgain() async {
        await openUnitPicker(tester);
        await tester.tap(find.text(l10nEn.customPortionAddAction).last);
        await tester.pumpAndSettle();
        await addServingThroughDialog(tester);
      }

      // Twice, with the selection moved away in between: the second save
      // leaves the stored list and the saved id exactly as the first did.
      for (var i = 0; i < 2; i++) {
        await tester.enterText(find.byType(TextFormField).first, '5');
        await tester.pumpAndSettle();
        bloc.add(
          UpdateKcalEvent(
            meal: _plainFood(),
            totalQuantity: '5',
            selectedUnit: 'g',
          ),
        );
        await tester.pumpAndSettle();
        expect(bloc.state.selectedUnit, 'g');

        await saveBowlAgain();

        expect(portions.rows, hasLength(1), reason: 'save #${i + 1}');
        expect(bloc.state.selectedUnit, 'serving', reason: 'save #${i + 1}');
        expect(quantityText(tester), '1', reason: 'save #${i + 1}');
        expect(bloc.state.totalQuantityConverted, '250.0');
      }
    });

    testWidgets('another food does not get it', (tester) async {
      await seedBowl();
      await pumpMealDetail(tester, _foodWithServing());

      await openUnitPicker(tester);
      expect(find.text('1 bowl'), findsNothing);
    });

    testWidgets('a long press deletes it after a confirm', (tester) async {
      await seedBowl();
      await pumpMealDetail(tester, _plainFood());
      await openUnitPicker(tester);
      await tester.tap(find.text('1 bowl').last);
      await tester.pumpAndSettle();
      expect(bloc.state.selectedUnit, 'serving');

      await openUnitPicker(tester);
      await tester.longPress(find.text('1 bowl').last);
      await tester.pumpAndSettle();
      expect(find.text(l10nEn.customPortionDeleteTitle), findsOneWidget);

      // Backing out keeps it.
      await tester.tap(find.text(l10nEn.dialogCancelLabel));
      await tester.pumpAndSettle();
      expect(portions.rows, hasLength(1));

      await openUnitPicker(tester);
      await tester.longPress(find.text('1 bowl').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nEn.dialogDeleteLabel));
      await tester.pumpAndSettle();

      expect(portions.rows, isEmpty);
      // The selection was the deleted serving: back to the defaults.
      expect(bloc.state.selectedUnit, 'g');
      expect(bloc.state.totalQuantityConverted, '100.0');
      expect(addServingChip(), findsOneWidget);
    });
  });
}

class _FakeGetConfigUsecase implements GetConfigUsecase {
  @override
  Future<ConfigEntity> getConfig() async =>
      const ConfigEntity(true, true, false, AppThemeEntity.system);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeAddIntakeUsecase implements AddIntakeUsecase {
  final logged = <IntakeEntity>[];

  @override
  Future<void> addIntake(IntakeEntity intakeEntity) async =>
      logged.add(intakeEntity);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeAddTrackedDayUsecase implements AddTrackedDayUsecase {
  @override
  Future<bool> hasTrackedDay(DateTime day) async => true;

  @override
  Future<void> addDayCaloriesTracked(DateTime day, double kcal) async {}

  @override
  Future<void> addDayMacrosTracked(
    DateTime day, {
    double? carbsTracked,
    double? fatTracked,
    double? proteinTracked,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeGetKcalGoalUsecase implements GetKcalGoalUsecase {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeGetMacroGoalUsecase implements GetMacroGoalUsecase {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeGetTrackedDayUsecase implements GetTrackedDayUsecase {
  @override
  Future<TrackedDayEntity?> getTrackedDay(DateTime day) async =>
      TrackedDayEntity(
        day: day,
        calorieGoal: 2200,
        caloriesTracked: 800,
        carbsGoal: 250,
        carbsTracked: 100,
        fatGoal: 70,
        fatTracked: 30,
        proteinGoal: 120,
        proteinTracked: 50,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeProductsRepository implements ProductsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeRemoteSearchCacheDataSource implements RemoteSearchCacheDataSource {
  @override
  Future<void> touch(String barcode) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeGetIntakeUsecase implements GetIntakeUsecase {
  @override
  Future<List<IntakeEntity>> getBreakfastIntakeByDay(
    DateTime day, {
    int dayStartOffsetHours = 0,
    int dayStartOffsetMinutes = 0,
  }) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeHomeBloc implements HomeBloc {
  @override
  void add(HomeEvent event) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeDiaryBloc implements DiaryBloc {
  @override
  void add(DiaryEvent event) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeCalendarDayBloc implements CalendarDayBloc {
  @override
  void add(CalendarDayEvent event) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _FakeCacheManager implements CacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      const Stream<FileResponse>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}
