import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/data/anthropic_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/data/meal_items_api_factory.dart';
import 'package:opennutritracker/features/add_meal/data/model_meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/data/openai_compatible_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_photo_usecase.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

class _MemoryStorage implements FlutterSecureStorage {
  final store = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => store[key];

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
      store.remove(key);
    } else {
      store[key] = value;
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
  }) async => store.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _primaryBase = 'https://generativelanguage.googleapis.com/v1beta/openai';
const _primaryModel = 'gemini-3.5-flash';
const _fallbackBase = 'https://api.groq.com/openai/v1';
const _fallbackModel = 'qwen/qwen3.8-27b';

final _photo = MealPhoto(
  bytes: Uint8List.fromList([1, 2, 3]),
  mediaType: 'image/jpeg',
);

/// The tool input of a one-dish reply.
const _reply = {
  'dishes': [
    {
      'name': 'Rice',
      'portion_g': 200,
      'servings': 1,
      'ingredients': [
        {
          'name': 'Rice, white, cooked',
          'grams': 200,
          'per100g': {
            'kcal': 130,
            'protein_g': 2.7,
            'carbs_g': 28.2,
            'fat_g': 0.3,
          },
        },
      ],
      'confidence': 'high',
      'assumptions': <String>[],
    },
  ],
};

/// An OpenAI-compatible chat completion carrying [_reply] as the tool call.
http.Response _completion() => http.Response(
  jsonEncode({
    'choices': [
      {
        'finish_reason': 'tool_calls',
        'message': {
          'tool_calls': [
            {
              'type': 'function',
              'function': {
                'name': 'log_meal_estimate',
                'arguments': jsonEncode(_reply),
              },
            },
          ],
        },
      },
    ],
  }),
  200,
);

/// Storage set up the way the settings dialog leaves it: Gemini as the
/// server the user runs, and optionally Groq as the fallback.
Future<AiCredentialStorage> _credentials({bool fallback = true}) async {
  final credentials = AiCredentialStorage(_MemoryStorage());
  await credentials.setActiveProvider(AiProvider.ownServer);
  await credentials.writeOwnServerConfiguration(
    endpoint: _primaryBase,
    model: _primaryModel,
    provider: AiProvider.ownServer,
  );
  await credentials.writeApiKey('primary-key', provider: AiProvider.ownServer);
  await credentials.setTermsAccepted(true);
  await credentials.setEnabled(true);
  if (fallback) {
    await credentials.writeFallbackConfiguration(
      endpoint: _fallbackBase,
      model: _fallbackModel,
      apiKey: 'fallback-key',
    );
  }
  return credentials;
}

/// The whole photo path over a fake network: the primary answers with
/// [primary], the fallback with a completion. Records which host was asked.
({ReadMealPhotoUseCase useCase, List<String> hosts}) _subject(
  AiCredentialStorage credentials,
  FutureOr<http.Response> Function() primary,
) {
  final hosts = <String>[];
  final client = MockClient((request) async {
    hosts.add(request.url.host);
    if (request.url.host == 'generativelanguage.googleapis.com') {
      return primary();
    }
    return _completion();
  });
  return (
    useCase: ReadMealPhotoUseCase(
      credentials,
      (selection) => ModelMealPhotoInterpreter(
        mealItemsApiFor(client, selection, timeout: const Duration(seconds: 1)),
      ),
    ),
    hosts: hosts,
  );
}

const _groq = 'api.groq.com';
const _google = 'generativelanguage.googleapis.com';

void main() {
  group('the fallback is asked once', () {
    for (final status in [429, 500, 503]) {
      test('after HTTP $status from the primary', () async {
        final subject = _subject(
          await _credentials(),
          () => http.Response(
            jsonEncode({
              'error': {'message': 'The model is overloaded.'},
            }),
            status,
          ),
        );

        final result = await subject.useCase.read(_photo);

        expect(subject.hosts, [_google, _groq]);
        final estimate = (result as MealPhotoRead).result.estimate!;
        expect(estimate.model, _fallbackModel);
        expect(
          estimate.dishes.single.assumptions,
          contains('Estimated with $_fallbackModel.'),
        );
      });
    }

    test('after the primary times out', () async {
      final subject = _subject(
        await _credentials(),
        () => Future.delayed(const Duration(seconds: 5), _completion),
      );

      final result = await subject.useCase.read(_photo);

      expect(subject.hosts, [_google, _groq]);
      expect((result as MealPhotoRead).result.estimate!.model, _fallbackModel);
    });
  });

  group('the fallback is not asked', () {
    test('after HTTP 400, which another provider would not fix', () async {
      final subject = _subject(
        await _credentials(),
        () => http.Response(
          jsonEncode({
            'error': {'message': 'Invalid image.'},
          }),
          400,
        ),
      );

      final result = await subject.useCase.read(_photo);

      expect(subject.hosts, [_google]);
      expect(result, isA<MealPhotoFailed>());
      expect((result as MealPhotoFailed).statusCode, 400);
    });

    test('when the primary answers, which names its own model', () async {
      final subject = _subject(await _credentials(), _completion);

      final result = await subject.useCase.read(_photo);

      expect(subject.hosts, [_google]);
      final estimate = (result as MealPhotoRead).result.estimate!;
      expect(estimate.model, _primaryModel);
      expect(estimate.dishes.single.assumptions, isEmpty);
    });

    test('when none is configured: the primary\'s failure stands', () async {
      final subject = _subject(
        await _credentials(fallback: false),
        () => http.Response('{"error": {"message": "busy"}}', 503),
      );

      final result = await subject.useCase.read(_photo);

      expect(subject.hosts, [_google]);
      expect((result as MealPhotoFailed).statusCode, 503);
      expect(result.providerMessage, 'busy');
    });
  });

  test('a fallback that fails too reports the primary\'s failure', () async {
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      return request.url.host == _google
          ? http.Response('{"error": {"message": "overloaded"}}', 503)
          : http.Response('{"error": {"message": "slow down"}}', 429);
    });
    final useCase = ReadMealPhotoUseCase(
      await _credentials(),
      (selection) =>
          ModelMealPhotoInterpreter(mealItemsApiFor(client, selection)),
    );

    final result = await useCase.read(_photo);

    expect(hosts, [_google, _groq]);
    expect((result as MealPhotoFailed).statusCode, 503);
    expect(result.providerMessage, 'overloaded');
  });

  test('which failures fall back', () {
    bool falls(MealInterpreterException e) =>
        ReadMealPhotoUseCase.shouldFallBack(e);

    expect(falls(const MealInterpreterException('x', statusCode: 429)), isTrue);
    expect(falls(const MealInterpreterException('x', statusCode: 500)), isTrue);
    expect(falls(const MealInterpreterException('x', statusCode: 503)), isTrue);
    expect(falls(const MealInterpreterException('x', timedOut: true)), isTrue);
    expect(
      falls(
        const MealInterpreterException(
          'x',
          failure: MealInterpreterFailure.timeout,
        ),
      ),
      isTrue,
    );
    expect(
      falls(const MealInterpreterException('x', statusCode: 400)),
      isFalse,
    );
    expect(
      falls(const MealInterpreterException('x', statusCode: 401)),
      isFalse,
    );
    expect(falls(const MealInterpreterException('no network')), isFalse);
  });

  group('the stored fallback', () {
    test(
      'is the OpenAI-compatible client at its address, with its key',
      () async {
        final selection = (await (await _credentials())
            .readFallbackSelection())!;

        expect(selection.provider, AiProvider.ownServer);
        expect(selection.endpoint, '$_fallbackBase/chat/completions');
        expect(selection.modelId, _fallbackModel);
        expect(selection.apiKey, 'fallback-key');
      },
    );

    test('is not a provider slot: switching provider keeps it', () async {
      final credentials = await _credentials();
      await credentials.setActiveProvider(AiProvider.anthropic);

      expect(await credentials.readFallbackSelection(), isNotNull);
    });

    test('a blank key forgets the key, a null one keeps it', () async {
      final credentials = await _credentials();
      await credentials.writeFallbackConfiguration(
        endpoint: _fallbackBase,
        model: _fallbackModel,
      );
      expect((await credentials.readFallbackSummary()).hasKey, isTrue);

      await credentials.writeFallbackConfiguration(
        endpoint: _fallbackBase,
        model: _fallbackModel,
        apiKey: '',
      );
      expect((await credentials.readFallbackSummary()).hasKey, isFalse);
    });

    test('an address or model that cannot be used is refused', () async {
      final credentials = await _credentials(fallback: false);

      expect(
        await credentials.writeFallbackConfiguration(
          endpoint: 'not a url',
          model: _fallbackModel,
        ),
        isFalse,
      );
      expect(
        await credentials.writeFallbackConfiguration(
          endpoint: _fallbackBase,
          model: '  ',
        ),
        isFalse,
      );
      expect(await credentials.readFallbackSelection(), isNull);
    });

    test('is forgotten by clearFallback and by clearAll', () async {
      final credentials = await _credentials();
      await credentials.clearFallback();
      expect(await credentials.readFallbackSelection(), isNull);

      final again = await _credentials();
      await again.clearAll();
      expect(await again.readFallbackSelection(), isNull);
      expect((await again.readFallbackSummary()).hasKey, isFalse);
    });
  });

  group('every request asks for a repeatable answer', () {
    Future<Map<String, dynamic>> bodyOf(
      MealPhotoToolApi Function(http.Client client) build,
    ) async {
      late Map<String, dynamic> body;
      final client = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 500);
      });
      try {
        await build(client).requestPhotoToolInput(
          content: const MealPhotoContent(
            mediaType: 'image/jpeg',
            base64Data: 'AAAA',
          ),
          system: 'system',
        );
      } on MealInterpreterException {
        // The answer does not matter, only what was asked.
      }
      return body;
    }

    test(
      'Google\'s OpenAI-compatible endpoint: temperature 0, top_p 1',
      () async {
        final body = await bodyOf(
          (client) => OpenAiCompatibleMealItemsApi(
            client,
            () => 'k',
            model: _primaryModel,
            endpoint: Uri.parse('$_primaryBase/chat/completions'),
          ),
        );
        expect(body['temperature'], 0);
        expect(body['top_p'], 1);
      },
    );

    test(
      'Groq and other servers the user runs: temperature 0, top_p 1',
      () async {
        final body = await bodyOf(
          (client) =>
              mealItemsApiFor(
                    client,
                    const AiSelection(
                      provider: AiProvider.ownServer,
                      endpoint: '$_fallbackBase/chat/completions',
                      modelId: _fallbackModel,
                      apiKey: 'k',
                    ),
                  )
                  as MealPhotoToolApi,
        );
        expect(body['temperature'], 0);
        expect(body['top_p'], 1);
      },
    );

    test('Anthropic: temperature 0, top_p left at its default', () async {
      final body = await bodyOf(
        (client) =>
            AnthropicMealItemsApi(client, () => 'k', model: 'claude-haiku-4-5'),
      );
      expect(body['temperature'], 0);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('OpenRouter: none, since it refuses to route one a model '
        'rejects', () async {
      final body = await bodyOf(
        (client) => OpenAiCompatibleMealItemsApi.openRouter(
          client,
          () => 'k',
          model: 'openai/gpt-5.6-luna',
        ),
      );
      expect(body.containsKey('temperature'), isFalse);
    });
  });

  test('the estimate keeps the model through withModel', () {
    const estimate = PhotoMealEstimate(dishes: []);
    expect(estimate.withModel('m').model, 'm');
  });

  test('a fallback result keeps every item the primary path would', () async {
    const result = MealTextParseResult(
      items: [ParsedMealItem(query: 'egg', quantity: 2)],
      errors: [],
    );
    expect(result.withEstimate(null).items, result.items);
  });
}
