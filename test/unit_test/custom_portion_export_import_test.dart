import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:opennutritracker/core/data/data_source/config_data_source.dart';
import 'package:opennutritracker/core/data/data_source/custom_activity_template_data_source.dart';
import 'package:opennutritracker/core/data/data_source/custom_activity_template_dbo.dart';
import 'package:opennutritracker/core/data/data_source/custom_meal_data_source.dart';
import 'package:opennutritracker/core/data/data_source/favourite_meal_data_source.dart';
import 'package:opennutritracker/core/data/data_source/intake_data_source.dart';
import 'package:opennutritracker/core/data/data_source/recipe_data_source.dart';
import 'package:opennutritracker/core/data/data_source/tracked_day_data_source.dart';
import 'package:opennutritracker/core/data/data_source/user_activity_data_source.dart';
import 'package:opennutritracker/core/data/data_source/user_activity_dbo.dart';
import 'package:opennutritracker/core/data/data_source/weight_log_data_source.dart';
import 'package:opennutritracker/core/data/dbo/config_dbo.dart';
import 'package:opennutritracker/core/data/dbo/custom_portion_dbo.dart';
import 'package:opennutritracker/core/data/dbo/favourite_meal_dbo.dart';
import 'package:opennutritracker/core/data/dbo/intake_dbo.dart';
import 'package:opennutritracker/core/data/dbo/meal_dbo.dart';
import 'package:opennutritracker/core/data/dbo/recipe_dbo.dart';
import 'package:opennutritracker/core/data/dbo/tracked_day_dbo.dart';
import 'package:opennutritracker/core/data/dbo/weight_log_dbo.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/core/data/repository/custom_activity_template_repository.dart';
import 'package:opennutritracker/core/data/repository/favourite_meal_repository.dart';
import 'package:opennutritracker/core/data/repository/intake_repository.dart';
import 'package:opennutritracker/core/data/repository/recipe_repository.dart';
import 'package:opennutritracker/core/data/repository/tracked_day_repository.dart';
import 'package:opennutritracker/core/data/repository/user_activity_repository.dart';
import 'package:opennutritracker/core/data/repository/weight_log_repository.dart';
import 'package:opennutritracker/features/custom_portion/data/data_source/custom_portion_data_source.dart';
import 'package:opennutritracker/features/custom_portion/data/repository/custom_portion_repository_impl.dart';
import 'package:opennutritracker/features/settings/domain/usecase/export_data_usecase.dart';
import 'package:opennutritracker/features/settings/domain/usecase/import_data_usecase.dart';
import 'package:opennutritracker/features/settings/presentation/bloc/export_import_bloc.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../helpers/fake_hive_db_provider.dart';
import '../helpers/hive_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

final class _PickedFile extends PlatformFile {
  _PickedFile(this.name, this.uri);

  @override
  final String name;

  @override
  final Uri uri;

  @override
  Never get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => null;

  @override
  Future<int> length() => File(path!).length();

  @override
  Future<Uint8List> readAsBytes() => File(path!).readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() => File(path!).openRead().cast();
}

// Every dataset but the custom portions is empty on both legs.
final _boxless = FakeHiveDBProvider();

class _EmptyUserActivityRepository extends UserActivityRepository {
  _EmptyUserActivityRepository() : super(UserActivityDataSource(_boxless));

  @override
  Future<List<UserActivityDBO>> getAllUserActivityDBO() async => [];

  @override
  Future<void> upsertAllUserActivityDBOs(List<UserActivityDBO> dbos) async {}
}

class _EmptyIntakeRepository extends IntakeRepository {
  _EmptyIntakeRepository() : super(IntakeDataSource(_boxless));

  @override
  Future<List<IntakeDBO>> getAllIntakesDBO() async => [];

  @override
  Future<void> upsertAllIntakeDBOs(List<IntakeDBO> intakeDBOs) async {}
}

class _EmptyTrackedDayRepository extends TrackedDayRepository {
  _EmptyTrackedDayRepository() : super(TrackedDayDataSource(_boxless));

  @override
  Future<List<TrackedDayDBO>> getAllTrackedDaysDBO() async => [];

  @override
  Future<void> addAllTrackedDays(List<TrackedDayDBO> trackedDaysDBO) async {}
}

class _EmptyRecipeRepository extends RecipeRepository {
  _EmptyRecipeRepository() : super(RecipeDataSource(_boxless));

  @override
  List<RecipeDBO> getAllRecipesDBO() => [];

  @override
  Future<void> addAllRecipeDBOs(List<RecipeDBO> recipes) async {}
}

class _EmptyCustomMealDataSource extends CustomMealDataSource {
  _EmptyCustomMealDataSource() : super(_boxless);

  @override
  List<MealDBO> getAllCustomMeals() => [];
}

class _EmptyWeightLogRepository extends WeightLogRepository {
  _EmptyWeightLogRepository() : super(WeightLogDataSource(_boxless));

  @override
  Future<List<WeightLogDBO>> getAllEntriesDBO() async => [];

  @override
  Future<void> addAllEntries(List<WeightLogDBO> entries) async {}
}

class _EmptyTemplateRepository extends CustomActivityTemplateRepository {
  _EmptyTemplateRepository()
    : super(CustomActivityTemplateDataSource(_boxless));

  @override
  Future<List<CustomActivityTemplateDBO>> allTemplateDBOs() async => [];

  @override
  Future<void> upsertAllTemplateDBOs(
    List<CustomActivityTemplateDBO> templates,
  ) async {}
}

class _EmptyConfigRepository extends ConfigRepository {
  _EmptyConfigRepository() : super(ConfigDataSource(_boxless));

  @override
  Future<ConfigDBO> getConfigDBO() async => ConfigDBO.empty();

  @override
  Future<void> setConfigGoalSettings({
    required double? kcalAdjustment,
    required double? carbGoalPct,
    required double? proteinGoalPct,
    required double? fatGoalPct,
    required Map<String, int>? mealKcalSharesPct,
    required int? dailyWaterGoalMl,
  }) async {}
}

class _EmptyFavouriteRepository extends FavouriteMealRepository {
  _EmptyFavouriteRepository()
    : super(
        FavouriteMealDataSource(_boxless),
        CustomMealDataSource(_boxless),
        RecipeDataSource(_boxless),
      );

  @override
  Future<List<FavouriteMealDBO>> getAllFavouritesDBO() async => [];

  @override
  Future<void> addAllFavouriteDBOs(List<FavouriteMealDBO> favourites) async {}
}

const _portionsFile = ExportDataUsecase.customPortionJsonFileName;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late PathProviderPlatform originalPathProvider;
  late Box<CustomPortionDBO> sourceBox;
  late Box<CustomPortionDBO> targetBox;

  CustomPortionRepositoryImpl repositoryOver(Box<CustomPortionDBO> box) =>
      CustomPortionRepositoryImpl(
        CustomPortionDataSource(FakeHiveDBProvider(customPortionBox: box)),
      );

  Future<Archive> exportFrom(
    CustomPortionRepositoryImpl? portions, {
    ExportFormat format = ExportFormat.json,
  }) => ExportDataUsecase(
    _EmptyUserActivityRepository(),
    _EmptyIntakeRepository(),
    _EmptyTrackedDayRepository(),
    _EmptyRecipeRepository(),
    _EmptyCustomMealDataSource(),
    _EmptyWeightLogRepository(),
    _EmptyTemplateRepository(),
    _EmptyConfigRepository(),
    _EmptyFavouriteRepository(),
    customPortionRepository: portions,
  ).assembleArchive(
    format: format,
    userActivityJsonFileName: ExportImportBloc.userActivityJsonFileName,
    userIntakeJsonFileName: ExportImportBloc.userIntakeJsonFileName,
    trackedDayJsonFileName: ExportImportBloc.trackedDayJsonFileName,
    recipeJsonFileName: ExportImportBloc.recipeJsonFileName,
    weightLogJsonFileName: ExportImportBloc.weightLogJsonFileName,
    customActivityTemplateJsonFileName:
        ExportImportBloc.customActivityTemplateJsonFileName,
    favouriteJsonFileName: ExportImportBloc.favouriteJsonFileName,
  );

  Future<bool> importInto(
    CustomPortionRepositoryImpl portions,
    Archive archive,
  ) async {
    final zip = File('${tempRoot.path}/backup.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    return ImportDataUsecase(
      _EmptyUserActivityRepository(),
      _EmptyIntakeRepository(),
      _EmptyTrackedDayRepository(),
      _EmptyRecipeRepository(),
      _EmptyWeightLogRepository(),
      _EmptyTemplateRepository(),
      _EmptyConfigRepository(),
      _EmptyFavouriteRepository(),
      pickFile: () async => _PickedFile('backup.zip', zip.uri),
      customPortionRepository: portions,
    ).importData(
      ExportImportBloc.userActivityJsonFileName,
      ExportImportBloc.userIntakeJsonFileName,
      ExportImportBloc.trackedDayJsonFileName,
      ExportImportBloc.recipeJsonFileName,
      ExportImportBloc.weightLogJsonFileName,
      ExportImportBloc.customActivityTemplateJsonFileName,
      favouriteJsonFileName: ExportImportBloc.favouriteJsonFileName,
    );
  }

  setUpAll(() {
    registerHiveAdaptersOnce();
  });

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ont_custom_portions_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempRoot.path);
    Hive.init(tempRoot.path);
    sourceBox = await Hive.openBox<CustomPortionDBO>('portions_export');
    targetBox = await Hive.openBox<CustomPortionDBO>('portions_import');
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    await Hive.close();
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  CustomPortionDBO portion(String id, String food, String label, double grams,
          {String unit = 'g'}) =>
      CustomPortionDBO(
        id: id,
        foodKey: food,
        label: label,
        gramWeight: grams,
        unit: unit,
        createdAt: DateTime(2026, 10, 1, 8),
      );

  test('a JSON export carries the servings and an import restores them', () async {
    await repositoryOver(sourceBox).upsertAllDBOs([
      portion('a', 'off:3017620422003', '1 bowl', 250),
      portion('b', 'custom:dal', '1 glass', 200.5, unit: 'ml'),
    ]);

    final archive = await exportFrom(repositoryOver(sourceBox));

    final entry = archive.findFile(_portionsFile);
    expect(entry, isNotNull);
    final exported =
        jsonDecode(utf8.decode(entry!.content as List<int>)) as List;
    expect(exported, hasLength(2));
    expect(exported.first['foodKey'], 'off:3017620422003');

    final importing = repositoryOver(targetBox);
    expect(await importInto(importing, archive), isTrue);

    final restored = await importing.getAllDBOs();
    expect(
      restored.map((p) => (p.id, p.foodKey, p.label, p.gramWeight, p.unit, p.createdAt)),
      [
        ('a', 'off:3017620422003', '1 bowl', 250.0, 'g', DateTime(2026, 10, 1, 8)),
        ('b', 'custom:dal', '1 glass', 200.5, 'ml', DateTime(2026, 10, 1, 8)),
      ],
    );
  });

  test('importing the same file twice leaves one of each', () async {
    await repositoryOver(sourceBox).upsertAllDBOs([
      portion('a', 'off:1', '1 bowl', 250),
    ]);
    final archive = await exportFrom(repositoryOver(sourceBox));

    final importing = repositoryOver(targetBox);
    await importInto(importing, archive);
    await importInto(importing, archive);

    expect(await importing.getAllDBOs(), hasLength(1));
  });

  test('servings already on the device that the file lacks stay', () async {
    await repositoryOver(sourceBox).upsertAllDBOs([
      portion('a', 'off:1', '1 bowl', 250),
    ]);
    final archive = await exportFrom(repositoryOver(sourceBox));

    final importing = repositoryOver(targetBox);
    await importing.upsertAllDBOs([portion('z', 'off:2', '1 cup', 240)]);
    await importInto(importing, archive);

    expect((await importing.getAllDBOs()).map((p) => p.id), ['a', 'z']);
  });

  test('a file from before custom servings existed still imports', () async {
    // Exactly what an older build wrote: everything but the new entry.
    final archive = await exportFrom(null);
    expect(archive.findFile(_portionsFile), isNull);

    final importing = repositoryOver(targetBox);
    await importing.upsertAllDBOs([portion('z', 'off:2', '1 cup', 240)]);

    expect(await importInto(importing, archive), isTrue);
    expect((await importing.getAllDBOs()).map((p) => p.id), ['z']);
  });

  test('an entry written without a unit reads as grams', () async {
    final archive = await exportFrom(null);
    final bytes = utf8.encode(
      jsonEncode([
        {
          'id': 'a',
          'foodKey': 'off:1',
          'label': '1 bowl',
          'gramWeight': 250,
          'createdAt': '2026-10-01T08:00:00.000',
        },
      ]),
    );
    archive.addFile(ArchiveFile(_portionsFile, bytes.length, bytes));

    final importing = repositoryOver(targetBox);
    await importInto(importing, archive);

    expect((await importing.getAllDBOs()).single.unit, 'g');
  });

  test('a CSV export leaves the servings out', () async {
    await repositoryOver(sourceBox).upsertAllDBOs([
      portion('a', 'off:1', '1 bowl', 250),
    ]);
    final archive = await exportFrom(
      repositoryOver(sourceBox),
      format: ExportFormat.csv,
    );
    expect(archive.findFile(_portionsFile), isNull);
  });
}
