import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/domain/ai_per100_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_photo_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_text_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/search_products_usecase.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

import '../../tool/replay/replay_core.dart';

/// The replay harness itself talks to a model and is not run in CI; this covers
/// the parts that do not need one.
void main() {
  group('photo ids', () {
    test('are the first ten characters of the content hash', () {
      // sha1("abc") is a9993e364706816aba3e25717850c26c9cd0d89d.
      expect(photoId(utf8.encode('abc')), 'a9993e3647');
    });

    test(
      'depend on the bytes, not on where the file lives or what it is called',
      () {
        final dir = Directory.systemTemp.createTempSync('replay_ids_');
        addTearDown(() => dir.deleteSync(recursive: true));
        Directory('${dir.path}/2026-10-28').createSync();
        final a = File('${dir.path}/IMG_2026-10-28_lunch_at_home.jpg')
          ..writeAsBytesSync([1, 2, 3]);
        final b = File('${dir.path}/2026-10-28/other.jpg')
          ..writeAsBytesSync([1, 2, 3]);

        expect(photoId(readBytes(a)), photoId(readBytes(b)));
        expect(photoId([1, 2, 3]), isNot(photoId([1, 2, 4])));
        expect(photoId([1, 2, 3]), hasLength(10));
      },
    );
  });

  group('finding photos', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('replay_find_');
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    test('takes images under the folder, recursively, in a stable order', () {
      Directory('${dir.path}/b').createSync();
      Directory('${dir.path}/a').createSync();
      for (final name in [
        'b/2.JPG',
        'a/1.jpeg',
        'a/3.png',
        'a/skip.txt',
        'a/skip.heic',
        'a/skip.gif',
      ]) {
        File('${dir.path}/$name').writeAsBytesSync([0]);
      }

      final found = listPhotos(
        dir,
      ).map((f) => f.path.substring(dir.path.length + 1));

      expect(found, ['a/1.jpeg', 'a/3.png', 'b/2.JPG']);
    });

    test('a sidecar text file is the caption', () {
      final photo = File('${dir.path}/x.jpg')..writeAsBytesSync([0]);
      File(
        '${dir.path}/x.txt',
      ).writeAsStringSync('  katsu chicken wrap, 250 g\n');

      expect(captionFor(photo), 'katsu chicken wrap, 250 g');
    });

    test('no sidecar, or a blank one, is no caption', () {
      final alone = File('${dir.path}/a.jpg')..writeAsBytesSync([0]);
      final blank = File('${dir.path}/b.jpg')..writeAsBytesSync([0]);
      File('${dir.path}/b.txt').writeAsStringSync('  \n');

      expect(captionFor(alone), isNull);
      expect(captionFor(blank), isNull);
    });
  });

  group('the output', () {
    const wrap = ReplayResult(
      id: 'a9993e3647',
      caption: 'wrap',
      dish: 'Katsu wrap',
      items: [
        ReplayItem(
          name: 'chicken',
          source: 'db',
          dbName: 'Chicken, fried',
          grams: 120.04,
          kcal: 300.26,
          proteinG: 25,
          carbsG: 10,
          fatG: 18,
          estimated: true,
        ),
        ReplayItem(
          name: 'mayo',
          source: 'ai_estimate',
          dbName: null,
          grams: 15,
          kcal: 100,
          proteinG: null,
          carbsG: 1,
          fatG: 11,
          estimated: false,
        ),
      ],
      unmatched: ['sauce'],
    );

    test('one photo has the documented shape', () {
      final json = wrap.toJson();

      expect(json.keys, [
        'id',
        'caption',
        'dish',
        'items',
        'unmatched',
        'total_kcal',
        'error',
        'portion_g',
        'confidence',
        'grounded',
        'ai_only',
      ]);
      final item = (json['items'] as List).first as Map;
      expect(item.keys, [
        'name',
        'source',
        'db_name',
        'grams',
        'kcal',
        'protein_g',
        'carbs_g',
        'fat_g',
        'estimated',
      ]);
      expect(item['grams'], 120.0, reason: 'rounded to a tenth');
      expect(json['total_kcal'], 400.3);
      expect(json['error'], isNull);
    });

    test('a failed photo carries only its id, caption and error', () {
      const failed = ReplayResult(id: 'abc', caption: null, error: 'transient');
      final json = failed.toJson();

      expect(json['items'], isEmpty);
      expect(json['total_kcal'], 0.0);
      expect(json['error'], 'transient');
      expect(json['grounded'], isNull);
      expect(json['ai_only'], isNull);
    });

    test('a provider error keeps its status and message, as its own kind', () {
      const failed = ReplayResult(
        id: 'abc',
        caption: null,
        error: 'providerError',
        httpStatus: 400,
        providerError: 'API key not valid. Please pass a valid API key.',
      );
      final json = failed.toJson();

      expect(json['error'], 'providerError');
      expect(json['error'], isNot('unreadable'));
      expect(json['http_status'], 400);
      expect(
        json['provider_error'],
        'API key not valid. Please pass a valid API key.',
      );
    });

    test('a failure with no HTTP answer has null status and message', () {
      const failed = ReplayResult(id: 'abc', caption: null, error: 'transient');
      final json = failed.toJson();

      expect(json['http_status'], isNull);
      expect(json['provider_error'], isNull);
    });

    test('an estimate reports grounded and ai-only totals side by side', () {
      const result = ReplayResult(
        id: 'abc',
        caption: null,
        dish: 'Dal',
        portionG: 300.04,
        confidence: 'medium',
        grounded: EstimateTotals(
          grams: 300,
          kcal: 410.26,
          proteinG: 20,
          carbsG: 50,
          fatG: 12,
        ),
        aiOnly: EstimateTotals(
          grams: 300,
          kcal: 380,
          proteinG: 19,
          carbsG: 48,
          fatG: 11,
        ),
      );
      final json = result.toJson();

      expect(json['portion_g'], 300.0);
      expect(json['confidence'], 'medium');
      expect((json['grounded'] as Map)['kcal'], 410.3);
      expect((json['ai_only'] as Map)['kcal'], 380.0);
    });

    test('the file names the model and the photos, and nothing else', () {
      final text = encodeReplay(
        model: 'm',
        baseUrl: 'https://example.test/v1',
        results: [wrap],
      );
      final decoded = jsonDecode(text) as Map;

      expect(decoded.keys, ['model', 'base_url', 'photos']);
      expect((decoded['photos'] as List).single['id'], 'a9993e3647');
    });
  });

  group('what the bloc would log', () {
    test(
      'db matches, AI estimates and unmatched foods are told apart',
      () async {
        const macros = AiPer100Estimate(
          kcal: 250,
          proteinG: 12,
          carbsG: 20,
          fatG: 13,
        );
        const items = [
          ParsedMealItem(
            query: 'lettuce',
            quantity: 20,
            unit: 'g',
            estimated: true,
            estimatedGrams: 20,
          ),
          ParsedMealItem(
            query: 'katsu sauce',
            quantity: 30,
            unit: 'g',
            estimated: true,
            estimatedGrams: 30,
            aiPer100: macros,
          ),
          ParsedMealItem(
            query: 'mystery',
            quantity: 10,
            unit: 'g',
            estimated: true,
            estimatedGrams: 10,
          ),
        ];
        final bloc = BulkAddBloc(
          ResolveParsedMealsUseCase(
            _Search({
              'lettuce': [_lettuce],
            }),
          ),
          ReadMealTextUseCase(
            AiCredentialStorage(_Storage()),
            (_) => throw StateError('unused'),
          ),
          _Reader(
            const MealPhotoRead(MealTextParseResult(items: items, errors: [])),
          ),
        );

        bloc.add(
          ReadMealPhotoEvent(
            photo: MealPhoto(bytes: _bytes, mediaType: 'image/jpeg'),
            usesImperialUnits: false,
            localeCode: 'en',
          ),
        );
        final state =
            await bloc.stream.firstWhere((s) => s is BulkAddLoadedState)
                as BulkAddLoadedState;
        final result = resultFromLoaded(id: 'x', caption: null, state: state);

        expect(result.items.map((i) => (i.name, i.source)), [
          ('lettuce', 'db'),
          ('katsu sauce', 'ai_estimate'),
        ]);
        final lettuce = result.items.first;
        expect(lettuce.dbName, 'Lettuce');
        expect(lettuce.grams, 20);
        expect(lettuce.kcal, closeTo(3, 1e-9));
        expect(lettuce.estimated, isTrue);
        final sauce = result.items.last;
        expect(sauce.dbName, isNull);
        expect(sauce.kcal, closeTo(75, 1e-9));
        expect(sauce.proteinG, closeTo(3.6, 1e-9));
        expect(result.unmatched, ['mystery']);
        expect(result.totalKcal, closeTo(78, 1e-9));
      },
    );
  });

  group('retry-after', () {
    test('reads seconds, case-insensitively', () {
      expect(retryAfter({'Retry-After': '7'}), const Duration(seconds: 7));
      expect(
        retryAfter({'retry-after': '1.5'}),
        const Duration(milliseconds: 1500),
      );
    });

    test('falls back when absent or not a number of seconds', () {
      expect(retryAfter({}), const Duration(seconds: 30));
      expect(
        retryAfter({'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT'}),
        const Duration(seconds: 30),
      );
      expect(retryAfter({'retry-after': '-4'}), const Duration(seconds: 30));
    });

    test('is capped', () {
      expect(retryAfter({'retry-after': '3600'}), const Duration(seconds: 120));
    });
  });

  group('pacing', () {
    test('three requests a minute means twenty seconds apart', () async {
      var now = DateTime(2026, 10, 29, 12);
      final waits = <Duration>[];
      final pacer = RequestPacer(
        minGap: const Duration(seconds: 20),
        now: () => now,
        wait: (d) async {
          waits.add(d);
          now = now.add(d);
        },
      );

      await pacer.acquire(); // the first goes straight out
      now = now.add(const Duration(seconds: 5));
      await pacer.acquire(); // 5 s later: owes 15
      now = now.add(const Duration(seconds: 30));
      await pacer.acquire(); // 30 s later: owes nothing

      expect(waits, [const Duration(seconds: 15)]);
    });
  });

  group('the transport', () {
    test(
      'retries a 429 after the provider\'s own wait, up to three times',
      () async {
        final inner = _Scripted([429, 429, 200]);
        final waits = <Duration>[];
        final client = ReplayHttpClient(
          inner,
          RequestPacer(minGap: Duration.zero),
          wait: (d) async => waits.add(d),
        );

        final response = await client.post(
          Uri.parse('https://x.test/v1'),
          body: '{"a":1}',
        );

        expect(response.statusCode, 200);
        expect(inner.bodies, [
          '{"a":1}',
          '{"a":1}',
          '{"a":1}',
        ], reason: 'the body is sent again');
        expect(waits, [const Duration(seconds: 2), const Duration(seconds: 2)]);
      },
    );

    test('gives up after three retries and returns the 429', () async {
      final inner = _Scripted([429, 429, 429, 429, 200]);
      final client = ReplayHttpClient(
        inner,
        RequestPacer(minGap: Duration.zero),
        wait: (_) async {},
      );

      final response = await client.post(
        Uri.parse('https://x.test/v1'),
        body: 'b',
      );

      expect(response.statusCode, 429);
      expect(inner.bodies, hasLength(4));
    });

    test('other statuses are not retried', () async {
      final inner = _Scripted([500, 200]);
      final client = ReplayHttpClient(
        inner,
        RequestPacer(minGap: Duration.zero),
        wait: (_) async {},
      );

      expect(
        (await client.post(
          Uri.parse('https://x.test/v1'),
          body: 'b',
        )).statusCode,
        500,
      );
      expect(inner.bodies, hasLength(1));
    });

    test('every request goes through the pacer, retries included', () async {
      var acquired = 0;
      final pacer = _CountingPacer(() => acquired++);
      final client = ReplayHttpClient(
        _Scripted([429, 200]),
        pacer,
        wait: (_) async {},
      );

      await client.post(Uri.parse('https://x.test/v1'), body: 'b');

      expect(acquired, 2);
    });

    test('logs a status and a wait, never an address or a body', () async {
      final lines = <String>[];
      final client = ReplayHttpClient(
        _Scripted([429, 200]),
        RequestPacer(minGap: Duration.zero),
        wait: (_) async {},
        log: lines.add,
      );

      await client.post(
        Uri.parse('https://secret-host.test/v1/key'),
        body: 'secret body',
      );

      expect(lines.join(), isNot(contains('secret')));
      expect(lines.single, contains('429'));
    });
  });
}

final _bytes = Uint8List.fromList([1, 2, 3]);

final _lettuce = MealEntity(
  code: 'lettuce',
  name: 'Lettuce',
  url: null,
  mealQuantity: null,
  mealUnit: 'g',
  servingQuantity: null,
  servingUnit: null,
  servingSize: null,
  source: MealSourceEntity.off,
  nutriments: const MealNutrimentsEntity(
    energyKcal100: 15,
    carbohydrates100: 3,
    fat100: 0,
    proteins100: 1,
    sugars100: null,
    saturatedFat100: null,
    fiber100: null,
  ),
);

class _Search implements SearchProductsUseCase {
  final Map<String, List<MealEntity>> off;

  _Search(this.off);

  @override
  Future<SearchProductsResult> searchOFFProductsByString(
    String searchString, {
    bool skipRemote = false,
  }) async => SearchProductsResult(
    meals: off[searchString] ?? const [],
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

class _Reader implements ReadMealPhotoUseCase {
  final MealPhotoReadResult reading;

  _Reader(this.reading);

  @override
  Future<MealPhotoReadResult> read(
    MealPhoto photo, {
    String? localeCode,
    String? caption,
  }) async => reading;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Storage extends Fake implements FlutterSecureStorage {}

class _CountingPacer extends RequestPacer {
  final void Function() onAcquire;

  _CountingPacer(this.onAcquire) : super(minGap: Duration.zero);

  @override
  Future<void> acquire() async => onAcquire();
}

/// Answers with the given statuses in turn; a 429 carries `retry-after: 2`.
class _Scripted extends http.BaseClient {
  final List<int> statuses;
  final bodies = <String>[];

  _Scripted(this.statuses);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    bodies.add((request as http.Request).body);
    final status = statuses[(bodies.length - 1).clamp(0, statuses.length - 1)];
    return http.StreamedResponse(
      Stream.value(utf8.encode('{}')),
      status,
      request: request,
      headers: status == 429 ? {'retry-after': '2'} : {},
    );
  }
}
