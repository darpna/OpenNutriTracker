// Photo replay harness: runs the app's real photo path on a folder of photos
// and writes what it would have logged for each. Not a test of anything; it is
// a `flutter test` file only because that is what can load the app's code
// headless. It lives outside test/, so the normal run never reaches it.
//
//   REPLAY_DIR=/path/to/photos REPLAY_OUT=replay.json REPLAY_API_KEY=… \
//     flutter test tool/replay/replay_test.dart
//
// See tool/replay/README.md. PRIVACY: photos are private. Nothing printed or
// written here may contain a file name or path; a photo is its `id`.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/data/data_sources/off_data_source.dart';
import 'package:opennutritracker/features/add_meal/data/data_sources/sp_food_data_source.dart';
import 'package:opennutritracker/features/add_meal/data/meal_items_api_factory.dart';
import 'package:opennutritracker/features/add_meal/data/model_meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/data/model_meal_text_interpreter.dart';
import 'package:opennutritracker/features/add_meal/data/repository/products_repository.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/food_number_cache.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_photo_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_text_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/search_products_usecase.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/add_meal/util/generic_food_table.dart';
import 'package:opennutritracker/features/add_meal/util/meal_photo_encoder.dart';

import 'dart_photo_preparer.dart';
import 'replay_core.dart';

const _defaultBaseUrl = 'https://api.groq.com/openai/v1';
const _defaultModel = 'qwen/qwen3.8-27b';

/// Groq's free tier allows 30 requests a minute and 8K tokens a minute, and an
/// image costs about 2,000 tokens: three requests a minute stays inside both.
const _defaultGapSeconds = 20;

String _setting(String name, String fallback) {
  final fromEnv = Platform.environment[name];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return fallback;
}

/// Food search for the replay: Open Food Facts only, with no local data, as the
/// fork has neither the Supabase backend nor a user's own foods to search. The
/// resolver, the ranking and the AI-estimate fallback are the app's own.
class _OffOnlySearch implements SearchProductsUseCase {
  final ProductsRepository _repository;

  _OffOnlySearch(this._repository);

  @override
  Future<SearchProductsResult> searchOFFProductsByString(
    String searchString, {
    bool skipRemote = false,
  }) async {
    try {
      return SearchProductsResult(
        meals: await _repository.getOFFProductsByString(searchString),
        remoteSourceEmpty: false,
      );
    } catch (_) {
      return const SearchProductsResult(
        meals: [],
        remoteSourceEmpty: true,
        remoteSourceFailed: true,
      );
    }
  }

  @override
  Future<SearchProductsResult> searchFDCFoodByString(
    String searchString, {
    bool skipRemote = false,
    bool forResolution = false,
  }) async => const SearchProductsResult(meals: [], remoteSourceEmpty: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoBackend extends Fake implements SpFoodDataSource {}

/// A keystore in memory, so the settings the app would read from the device are
/// written here and the key never touches disk.
class _MemoryStorage extends Fake implements FlutterSecureStorage {
  final _values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values.remove(key);
}

/// The bundled USDA table, read from the asset file (a plain `flutter test`
/// has no asset bundle for the app's own assets).
Future<GenericFoodTable?> _bundledTable() async =>
    GenericFoodTable.fromGzipBytes(
      File(GenericFoodTable.assetPath).readAsBytesSync(),
    );

void main() {
  final dirPath = _setting('REPLAY_DIR', '');
  final outPath = _setting('REPLAY_OUT', 'replay.json');
  // REPLAY_API_KEY for whatever REPLAY_BASE_URL names; GROQ_API_KEY still
  // works, as it did when Groq was the only provider the harness ran.
  final apiKey = _setting('REPLAY_API_KEY', _setting('GROQ_API_KEY', ''));
  final baseUrl = _setting('REPLAY_BASE_URL', _defaultBaseUrl);
  final model = _setting('REPLAY_MODEL', _defaultModel);
  final runs = math.max(1, int.tryParse(_setting('REPLAY_RUNS', '1')) ?? 1);
  // The fallback, asked when the primary times out, rate-limits or fails on
  // its side, exactly as the app asks it. Off unless both are set.
  final fallbackBaseUrl = _setting('REPLAY_FALLBACK_BASE_URL', '');
  final fallbackModel = _setting('REPLAY_FALLBACK_MODEL', '');
  final fallbackKey = _setting('REPLAY_FALLBACK_API_KEY', '');
  final hasFallback = fallbackBaseUrl.isNotEmpty && fallbackModel.isNotEmpty;

  final skip = dirPath.isEmpty
      ? 'REPLAY_DIR is not set'
      : apiKey.isEmpty
      ? 'REPLAY_API_KEY is not set'
      : !Directory(dirPath).existsSync()
      ? 'REPLAY_DIR does not exist'
      : null;
  if (skip != null) {
    // ignore: avoid_print
    print('SKIPPED: $skip');
  }

  test(
    'replay the photos',
    () async {
      final photos = listPhotos(Directory(dirPath));
      // ignore: avoid_print
      print(
        'replaying ${photos.length} photo(s) x $runs run(s) with $model'
        '${hasFallback ? ', falling back to $fallbackModel' : ''}',
      );

      // The settings the app reads from the device, written the way the
      // settings dialog writes them.
      final credentials = AiCredentialStorage(_MemoryStorage());
      await credentials.setActiveProvider(AiProvider.ownServer);
      expect(
        await credentials.writeOwnServerConfiguration(
          endpoint: baseUrl,
          model: model,
          provider: AiProvider.ownServer,
        ),
        isTrue,
        reason: 'the base URL and model must be usable',
      );
      await credentials.writeApiKey(apiKey, provider: AiProvider.ownServer);
      await credentials.setTermsAccepted(true);
      await credentials.setEnabled(true);
      if (hasFallback) {
        expect(
          await credentials.writeFallbackConfiguration(
            endpoint: fallbackBaseUrl,
            model: fallbackModel,
            apiKey: fallbackKey,
          ),
          isTrue,
          reason: 'the fallback base URL and model must be usable',
        );
      }
      final selection = await credentials.readSelection();
      expect(selection, isNotNull, reason: 'the AI settings must be usable');

      final gap = Duration(
        seconds:
            int.tryParse(_setting('REPLAY_MIN_GAP_SECONDS', '')) ??
            _defaultGapSeconds,
      );
      // ignore: avoid_print
      void log(String line) => print('  $line');
      // Each provider has its own rate limit, so each gets its own pacer. With
      // a fallback the primary's 429 is not retried here: it is one of the
      // failures the app hands to the fallback, and the replay should see the
      // app do that rather than wait it out.
      final primaryTransport = ReplayHttpClient(
        http.Client(),
        RequestPacer(minGap: gap),
        maxRetries: hasFallback ? 0 : 3,
        log: log,
      );
      final fallbackTransport = ReplayHttpClient(
        http.Client(),
        RequestPacer(minGap: gap),
        log: log,
      );
      // One cache for the whole replay, as a phone keeps one: the second time
      // a food comes up it gets the numbers the first settled on.
      final cache = MemoryFoodNumberCache();
      MealItemsApi apiFor(AiSelection selection) => mealItemsApiFor(
        selection.endpoint == null ||
                AiCredentialStorage.resolveEndpoint(selection.endpoint!) ==
                    AiCredentialStorage.resolveEndpoint(baseUrl)
            ? primaryTransport
            : fallbackTransport,
        selection,
      );
      final photoReader = ReadMealPhotoUseCase(
        credentials,
        (selection) => ModelMealPhotoInterpreter(
          apiFor(selection),
          table: _bundledTable,
          cache: cache,
        ),
      );
      // The text reader is part of the bloc's constructor and never used here.
      final textReader = ReadMealTextUseCase(
        credentials,
        (selection) => ModelMealTextInterpreter(apiFor(selection)),
      );
      final resolver = ResolveParsedMealsUseCase(
        _OffOnlySearch(ProductsRepository(OFFDataSource(), _NoBackend())),
      );
      const preparer = DartPhotoPreparer();

      final results = <ReplayResult>[];
      for (var run = 1; run <= runs; run++) {
        for (var i = 0; i < photos.length; i++) {
          final file = photos[i];
          final bytes = readBytes(file);
          final id = photoId(bytes);
          final caption = captionFor(file);
          final label =
              '${runs > 1 ? 'run $run ' : ''}[${i + 1}/${photos.length}] $id';

          final photo = await preparer.prepare(
            file.path,
            MealPhotoFormat.forProvider(AiProvider.ownServer),
          );
          if (photo == null) {
            // ignore: avoid_print
            print('$label could not be encoded');
            results.add(
              ReplayResult(
                id: id,
                caption: caption,
                run: run,
                error: 'unreadable',
              ),
            );
            continue;
          }

          // A bloc per photo, as the screen gets one per visit.
          final bloc = BulkAddBloc(resolver, textReader, photoReader);
          bloc.add(
            ReadMealPhotoEvent(
              photo: photo,
              usesImperialUnits: false,
              localeCode: 'en',
              caption: caption,
            ),
          );
          final state = await bloc.stream.firstWhere(
            (s) => s is! BulkAddLoadingState,
          );
          await bloc.close();

          final result = switch (state) {
            BulkAddLoadedState() => resultFromLoaded(
              id: id,
              caption: caption,
              state: state,
              run: run,
            ),
            BulkAddPhotoErrorState(
              :final error,
              :final httpStatus,
              :final providerMessage,
            ) =>
              ReplayResult(
                id: id,
                caption: caption,
                run: run,
                error: error.name,
                httpStatus: httpStatus,
                providerError: providerMessage,
              ),
            _ => ReplayResult(
              id: id,
              caption: caption,
              run: run,
              error: 'search_failed',
            ),
          };
          // ignore: avoid_print
          print(
            '$label ${result.error ?? '${result.dishes.length} dish(es), '
                    '${result.items.length} item(s), '
                    '${result.totalKcal.round()} kcal'
                    '${result.modelUsed == model ? '' : ' (${result.modelUsed})'}'}',
          );
          results.add(result);
        }
      }

      File(outPath).writeAsStringSync(
        encodeReplay(
          model: model,
          baseUrl: baseUrl,
          results: results,
          runs: runs,
          fallbackModel: hasFallback ? fallbackModel : null,
          fallbackBaseUrl: hasFallback ? fallbackBaseUrl : null,
        ),
      );
      // ignore: avoid_print
      print('wrote ${results.length} result(s)');
      // The run is a measurement, not a check: a photo that failed is in the
      // output with its error, and does not fail the job.
      expect(results, hasLength(photos.length * runs));
    },
    skip: skip,
    timeout: const Timeout(Duration(hours: 5)),
  );
}
