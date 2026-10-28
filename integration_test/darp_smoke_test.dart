import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/core/data/repository/custom_activity_template_repository.dart';
import 'package:opennutritracker/core/data/repository/favourite_meal_repository.dart';
import 'package:opennutritracker/core/data/repository/intake_repository.dart';
import 'package:opennutritracker/core/data/repository/recipe_repository.dart';
import 'package:opennutritracker/core/data/repository/tracked_day_repository.dart';
import 'package:opennutritracker/core/data/repository/user_activity_repository.dart';
import 'package:opennutritracker/core/data/repository/weight_log_repository.dart';
import 'package:opennutritracker/core/domain/entity/app_theme_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_gender_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_pal_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_weight_goal_entity.dart';
import 'package:opennutritracker/core/domain/usecase/add_config_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/add_user_usecase.dart';
import 'package:opennutritracker/core/presentation/main_screen.dart';
import 'package:opennutritracker/core/presentation/widgets/intake_card.dart';
import 'package:opennutritracker/core/utils/hive_db_provider.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/logger_config.dart';
import 'package:opennutritracker/core/utils/navigation_options.dart';
import 'package:opennutritracker/core/utils/tracked_day_reconciler.dart';
import 'package:opennutritracker/features/add_meal/data/repository/products_repository.dart';
import 'package:opennutritracker/features/add_meal/presentation/add_meal_screen.dart';
import 'package:opennutritracker/features/add_meal/presentation/add_meal_type.dart';
import 'package:opennutritracker/features/diary/diary_page.dart';
import 'package:opennutritracker/features/home/home_page.dart';
import 'package:opennutritracker/features/settings/domain/usecase/export_data_usecase.dart';
import 'package:opennutritracker/features/settings/domain/usecase/import_data_usecase.dart';
import 'package:opennutritracker/features/settings/presentation/bloc/export_import_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';
import 'package:opennutritracker/main.dart' as app;
import 'package:path_provider/path_provider.dart';

import 'fixtures/darp_smoke_fixture.dart';

/// Pre-APK gate for the darp fork, run on an Android emulator by the `smoke`
/// job in `.github/workflows/darp-apk.yml`.
///
/// Three gated checks, all offline and deterministic:
///   A  starts with existing data - a synthetic export (see
///      `fixtures/darp_smoke_fixture.dart`) goes in through the same
///      `ImportDataUsecase` Settings > Import uses, then Home and the diary
///      must render the seeded entries.
///   B  logs a meal offline - Quick Add through the real sheet, then the
///      diary shows it with the typed kcal.
///   C  export/import round trip - `ExportDataUsecase.assembleArchive` (the
///      bytes `exportData` hands the save dialog), wipe, import, counts and
///      kcal total match.
///
/// A fourth, REPORT-ONLY block searches Open Food Facts and the Supabase food
/// backend for "tomato" and prints `RESULT` lines. It cannot fail the run: it
/// depends on the network and, on this fork, on a placeholder Supabase URL.
///
/// One boot for the whole file, like `app_boot_test.dart` and for the same
/// reason: `initLocator()` has no re-registration guard. Boot goes through
/// `initLocator()` + `runAppWithChangeNotifiers` as `store_screenshots_test`
/// does, so the seed lands before the first frame instead of after onboarding.
///
/// Every gate runs even if an earlier one failed, so one run shows everything
/// that is broken; the test fails at the end if any gate did.
/// Skips itself unless `--dart-define=DARP_SMOKE=true`. Upstream's
/// `android-integration-tests` and the iOS lane run `flutter test
/// integration_test/` over the whole directory, and this file must not join
/// them - the same device `store_screenshots_test.dart` uses.
const bool _enabled = bool.fromEnvironment('DARP_SMOKE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('darp smoke: start with data, log a meal, round trip', (
    WidgetTester tester,
  ) async {
    // Disposed at the end of the body, not via addTearDown - see the note in
    // store_screenshots_test.dart on why a teardown is too late.
    final semantics = tester.ensureSemantics();
    final gates = <String, Object?>{};

    Future<void> gate(String name, Future<void> Function() body) async {
      final timer = Stopwatch()..start();
      try {
        await body();
        gates[name] = null;
        _result('gate=$name status=PASS ms=${timer.elapsedMilliseconds}');
      } catch (e, st) {
        gates[name] = e;
        _result(
          'gate=$name status=FAIL ms=${timer.elapsedMilliseconds} '
          'error=${_oneLine(e)}',
        );
        debugPrint('$name failed: $e\n$st');
      }
    }

    LoggerConfig.intiLogger();
    await initLocator();

    final hive = locator<HiveDBProvider>();
    final today = DateTime.now();
    final tmp = await getTemporaryDirectory();
    final fixtureFiles = SmokeFixture.files(today);

    // ---- GATE A: boot over existing data ------------------------------
    await gate('A-start-with-data', () async {
      // A profile the way onboarding leaves one. Nothing else is seeded
      // directly: the entries below go through the importer.
      await locator<AddUserUsecase>().addUser(
        UserEntity(
          birthday: DateTime(today.year - 30, 4, 12),
          heightCM: 178,
          weightKG: 80,
          gender: UserGenderEntity.male,
          goal: UserWeightGoalEntity.maintainWeight,
          pal: UserPALEntity.active,
        ),
      );
      // Same reason as in store_screenshots_test: the disclaimer dialog is a
      // modal barrier over HomePage on a fresh profile.
      await locator<AddConfigUsecase>().setConfigDisclaimer(true);

      final zip = await _writeZip(tmp, 'smoke_fixture.zip', fixtureFiles);
      await _importer(zip).importData(
        ExportImportBloc.userActivityJsonFileName,
        ExportImportBloc.userIntakeJsonFileName,
        ExportImportBloc.trackedDayJsonFileName,
        ExportImportBloc.recipeJsonFileName,
        ExportImportBloc.weightLogJsonFileName,
        ExportImportBloc.customActivityTemplateJsonFileName,
      );
      expect(
        hive.intakeBox.length,
        SmokeFixture.intakeCount,
        reason: 'import should have written the fixture intakes',
      );

      app.runAppWithChangeNotifiers(
        true,
        AppThemeEntity.light,
        const Locale('en'),
        false, // kcal
        false, // Material You off
        null,
      );
      await _pumpUntil(tester, find.byType(MainScreen), what: 'MainScreen');
      await _pumpUntil(tester, find.byType(HomePage), what: 'HomePage');

      for (final (name, kcal) in SmokeFixture.todayIntakes) {
        await _expectCard(tester, HomePage, name, kcal);
      }

      await _tapNav(tester, 'nav-diary');
      await _pumpUntil(tester, find.byType(DiaryPage), what: 'DiaryPage');
      for (final (name, kcal) in SmokeFixture.todayIntakes) {
        await _expectCard(tester, DiaryPage, name, kcal);
      }
    });

    // ---- GATE B: log a meal with no network ---------------------------
    const quickName = 'Smoke Quick Meal';
    const quickKcal = 333;
    await gate('B-log-meal-offline', () async {
      await _tapNav(tester, 'nav-home');
      final navigator = Navigator.of(tester.element(find.byType(MainScreen)));
      unawaited(
        navigator.pushNamed(
          NavigationOptions.addMealRoute,
          arguments: AddMealScreenArguments(AddMealType.lunchType, today),
        ),
      );
      await _pumpUntil(
        tester,
        find.bySemanticsIdentifier('add-meal-quick-add'),
        what: 'Quick Add button',
      );
      await tester.tap(find.bySemanticsIdentifier('add-meal-quick-add'));
      await _pumpUntil(
        tester,
        find.bySemanticsIdentifier('quick-add-title'),
        what: 'Quick Add sheet',
      );
      await _typeInto(tester, 'quick-add-title', quickName);
      await _typeInto(tester, 'quick-add-energy', '$quickKcal');
      await tester.pump();
      await tester.tap(find.bySemanticsIdentifier('quick-add-submit'));
      // Submit pushes a fresh main route over everything.
      await _pumpUntil(tester, find.byType(MainScreen), what: 'MainScreen');
      await _pumpUntil(
        tester,
        find.byType(AddMealScreen),
        what: 'AddMealScreen gone',
        gone: true,
      );

      expect(
        hive.intakeBox.length,
        SmokeFixture.intakeCount + 1,
        reason: 'Quick Add should have stored one more intake',
      );
      final stored = hive.intakeBox.values.singleWhere(
        (i) => i.meal.name == quickName,
      );
      expect(
        stored.amount * (stored.meal.nutriments.energyKcal100! / 100),
        quickKcal.toDouble(),
      );

      await _tapNav(tester, 'nav-diary');
      await _expectCard(tester, DiaryPage, quickName, quickKcal);
    });

    // ---- GATE C: export -> wipe -> import ------------------------------
    await gate('C-export-import-roundtrip', () async {
      final before = _counts(hive);
      expect(
        before.intakes,
        SmokeFixture.intakeCount + 1,
        reason: 'round trip needs data to carry; did gate B run?',
      );

      final archive = await locator<ExportDataUsecase>().assembleArchive(
        format: ExportFormat.json,
        userActivityJsonFileName: ExportImportBloc.userActivityJsonFileName,
        userIntakeJsonFileName: ExportImportBloc.userIntakeJsonFileName,
        trackedDayJsonFileName: ExportImportBloc.trackedDayJsonFileName,
        recipeJsonFileName: ExportImportBloc.recipeJsonFileName,
        weightLogJsonFileName: ExportImportBloc.weightLogJsonFileName,
        customActivityTemplateJsonFileName:
            ExportImportBloc.customActivityTemplateJsonFileName,
        goalSettingsJsonFileName: ExportImportBloc.goalSettingsJsonFileName,
        favouriteJsonFileName: ExportImportBloc.favouriteJsonFileName,
      );
      final zip = File('${tmp.path}/smoke_roundtrip.zip');
      await zip.writeAsBytes(ZipEncoder().encode(archive), flush: true);

      await hive.intakeBox.clear();
      await hive.userActivityBox.clear();
      await hive.trackedDayBox.clear();
      expect(_counts(hive).intakes, 0, reason: 'wipe did not empty the box');

      await _importer(zip.path).importData(
        ExportImportBloc.userActivityJsonFileName,
        ExportImportBloc.userIntakeJsonFileName,
        ExportImportBloc.trackedDayJsonFileName,
        ExportImportBloc.recipeJsonFileName,
        ExportImportBloc.weightLogJsonFileName,
        ExportImportBloc.customActivityTemplateJsonFileName,
        goalSettingsJsonFileName: ExportImportBloc.goalSettingsJsonFileName,
        favouriteJsonFileName: ExportImportBloc.favouriteJsonFileName,
      );

      final after = _counts(hive);
      expect(after.intakes, before.intakes, reason: 'intake count');
      expect(after.activities, before.activities, reason: 'activity count');
      expect(after.trackedDays, before.trackedDays, reason: 'tracked days');
      expect(after.kcal, before.kcal, reason: 'total logged kcal');
      _result(
        'roundtrip intakes=${after.intakes} activities=${after.activities} '
        'trackedDays=${after.trackedDays} kcal=${after.kcal}',
      );
    });

    // ---- REPORT ONLY: food search -------------------------------------
    final products = locator<ProductsRepository>();
    await _reportSearch('OFF', () => products.getOFFProductsByString('tomato'));
    await _reportSearch(
      'FDC',
      () => products.getSupabaseFoodsByString('tomato'),
    );

    semantics.dispose();

    final failed = gates.entries.where((e) => e.value != null).toList();
    expect(
      failed,
      isEmpty,
      reason:
          'failed gates: '
          '${failed.map((e) => '${e.key}: ${_oneLine(e.value)}').join('; ')}',
    );
  }, skip: !_enabled);
}

void _result(String line) => debugPrint('RESULT $line');

String _oneLine(Object? e) {
  final text = '$e'.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length > 200 ? '${text.substring(0, 200)}...' : text;
}

/// The importer Settings uses, with the file picker swapped for [zipPath].
/// `FilePicker.pickFile` opens a system UI the test cannot drive.
ImportDataUsecase _importer(String zipPath) => ImportDataUsecase(
  locator<UserActivityRepository>(),
  locator<IntakeRepository>(),
  locator<TrackedDayRepository>(),
  locator<RecipeRepository>(),
  locator<WeightLogRepository>(),
  locator<CustomActivityTemplateRepository>(),
  locator<ConfigRepository>(),
  locator<FavouriteMealRepository>(),
  pickFile: () async => _PickedFile(zipPath),
  restoreTrackedDays:
      (
        write, {
        required importedDayKeys,
        required importedActivities,
        required keyedByOffsetMinutes,
      }) => restoreTrackedDays(
        locator<HiveDBProvider>(),
        locator(),
        write: write,
        importedDayKeys: importedDayKeys,
        importedActivities: importedActivities,
        keyedByOffsetMinutes: keyedByOffsetMinutes,
      ),
);

Future<String> _writeZip(
  Directory dir,
  String name,
  Map<String, String> files,
) async {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = entry.value.codeUnits;
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(ZipEncoder().encode(archive), flush: true);
  return file.path;
}

({int intakes, int activities, int trackedDays, double kcal}) _counts(
  HiveDBProvider hive,
) => (
  intakes: hive.intakeBox.length,
  activities: hive.userActivityBox.length,
  trackedDays: hive.trackedDayBox.length,
  kcal: hive.intakeBox.values.fold<double>(
    0,
    (sum, i) => sum + i.amount * ((i.meal.nutriments.energyKcal100 ?? 0) / 100),
  ),
);

/// Pumps frames until [finder] matches (or, with [gone], stops matching).
/// Not `pumpAndSettle`: Home and the diary keep a spinner or animation alive
/// while their blocs load, so "no frame scheduled" is the wrong condition.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  required String what,
  bool gone = false,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty == gone) {
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  throw TestFailure('timed out after ${timeout.inSeconds}s waiting for $what');
}

Future<void> _tapNav(WidgetTester tester, String identifier) async {
  final item = find.bySemanticsIdentifier(identifier);
  await _pumpUntil(tester, item, what: 'nav item $identifier');
  await tester.tap(item);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _typeInto(
  WidgetTester tester,
  String identifier,
  String text,
) async {
  final field = find.descendant(
    of: find.bySemanticsIdentifier(identifier),
    matching: find.byType(TextField),
  );
  await tester.enterText(field, text);
  await tester.pump();
}

/// Scrolls [page]'s first scrollable until the card named [name] is on screen,
/// then checks the kcal on that same card. Both Home and Diary list meals in a
/// `ListView` that builds lazily, so an entry below the fold is not in the tree.
Future<void> _expectCard(
  WidgetTester tester,
  Type page,
  String name,
  int kcal,
) async {
  final scrollable = find
      .descendant(of: find.byType(page), matching: find.byType(Scrollable))
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump(const Duration(milliseconds: 100));

  final title = find.descendant(
    of: find.byType(page),
    matching: find.text(name),
  );
  await tester.scrollUntilVisible(
    title,
    240,
    scrollable: scrollable,
    maxScrolls: 80,
  );
  await tester.pump(const Duration(milliseconds: 100));

  final card = find.ancestor(of: title, matching: find.byType(IntakeCard));
  expect(
    card,
    findsOneWidget,
    reason: '"$name" should render as an IntakeCard',
  );
  final unit = S.of(tester.element(card)).kcalLabel;
  // The card shows `(amount * (kcal100 / 100)).toInt()`, which truncates:
  // 100 * (410 / 100) is 409.99999999999994 and renders as "409". Mirror that
  // arithmetic instead of asserting the nominal value.
  final shown = (100.0 * (kcal / 100.0)).toInt();
  expect(
    find.descendant(of: card, matching: find.text('$shown $unit')),
    findsOneWidget,
    reason: '"$name" should show $shown $unit on ${page.toString()}',
  );
}

/// Up to three tries; prints one RESULT line either way. Never throws.
Future<void> _reportSearch(
  String source,
  Future<List<Object?>> Function() search,
) async {
  const maxTries = 3;
  String line = 'search source=$source status=not-run';
  for (var attempt = 1; attempt <= maxTries; attempt++) {
    final timer = Stopwatch()..start();
    try {
      final hits = await search().timeout(const Duration(seconds: 25));
      line =
          'search source=$source status=ok hits=${hits.length} '
          'ms=${timer.elapsedMilliseconds} tries=$attempt';
      if (hits.isNotEmpty) break;
    } catch (e) {
      line =
          'search source=$source status=error hits=0 '
          'ms=${timer.elapsedMilliseconds} tries=$attempt '
          'error=${e.runtimeType}: ${_oneLine(e)}';
    }
    if (attempt < maxTries) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  _result(line);
}

/// A pick of a local file, shaped like the picks in
/// `test/unit_test/import_data_usecase_off_repair_test.dart`.
final class _PickedFile extends PlatformFile {
  _PickedFile(String path) : uri = Uri.file(path);

  @override
  final Uri uri;

  @override
  String get name => uri.pathSegments.last;

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
