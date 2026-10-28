import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/features/add_meal/data/anthropic_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/data/model_meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/data/openai_compatible_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/data/openai_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

/// Replays canned replies in order and records every request body. Nothing
/// here touches the network.
class _ScriptedClient extends http.BaseClient {
  final List<(int, String)> replies;
  final sent = <Map<String, dynamic>>[];

  _ScriptedClient(this.replies);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(jsonDecode((request as http.Request).body) as Map<String, dynamic>);
    final (status, body) = replies[(sent.length - 1).clamp(0, replies.length - 1)];
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

String _anthropicReply(String tool, Map<String, Object?> input) => jsonEncode({
  'content': [
    {'type': 'tool_use', 'id': 't', 'name': tool, 'input': input},
  ],
});

Map<String, Object?> _component(String query, num grams) => {
  'query': query,
  'grams': grams,
  'per_100g': {'kcal': 200, 'protein_g': 10, 'carbs_g': 20, 'fat_g': 8},
};

Map<String, Object?> get _wrapReply => {
  'dish': {
    'name': 'Katsu chicken wrap',
    'components': [
      _component('flour tortilla', 70),
      _component('breaded fried chicken', 120),
      _component('lettuce', 20),
    ],
  },
  'items': <Object?>[],
};

final _photo = MealPhoto(
  bytes: Uint8List.fromList([1, 2, 3, 4]),
  mediaType: 'image/webp',
);

ModelMealPhotoInterpreter _anthropic(_ScriptedClient client) =>
    ModelMealPhotoInterpreter(AnthropicMealItemsApi(client, () => 'k'));

void main() {
  group('the estimate reading', () {
    test('asks for the photo tool and returns the dish with estimates', () async {
      final client = _ScriptedClient([
        (200, _anthropicReply(mealPhotoToolName, _wrapReply)),
      ]);

      final result = await _anthropic(client).interpret(_photo);

      expect(client.sent, hasLength(1));
      final request = client.sent.single;
      expect((request['tools'] as List).single['name'], mealPhotoToolName);
      expect(request['tool_choice'], {'type': 'tool', 'name': mealPhotoToolName});
      expect(result.dish!.name, 'Katsu chicken wrap');
      expect(result.dish!.components.map((c) => c.query), [
        'flour tortilla',
        'breaded fried chicken',
        'lettuce',
      ]);
      expect(result.dish!.components.every((c) => c.estimated), isTrue);
      expect(result.dish!.components.every((c) => c.aiPer100 != null), isTrue);
    });

    test('one prompt and one schema go to every provider', () async {
      final anthropic = _ScriptedClient([
        (200, _anthropicReply(mealPhotoToolName, _wrapReply)),
      ]);
      await _anthropic(anthropic).interpret(_photo);

      final openAiReply = jsonEncode({
        'output': [
          {
            'type': 'function_call',
            'name': mealPhotoToolName,
            'arguments': jsonEncode(_wrapReply),
          },
        ],
      });
      final openAi = _ScriptedClient([(200, openAiReply)]);
      await ModelMealPhotoInterpreter(
        OpenAiMealItemsApi(openAi, () => 'k', model: 'm'),
      ).interpret(_photo);

      final compatibleReply = jsonEncode({
        'choices': [
          {
            'message': {
              'tool_calls': [
                {
                  'function': {
                    'name': mealPhotoToolName,
                    'arguments': jsonEncode(_wrapReply),
                  },
                },
              ],
            },
          },
        ],
      });
      final compatible = _ScriptedClient([(200, compatibleReply)]);
      final viaCompatible = await ModelMealPhotoInterpreter(
        OpenAiCompatibleMealItemsApi.openRouter(compatible, () => 'k', model: 'm'),
      ).interpret(_photo);
      expect(viaCompatible.dish!.components, hasLength(3));

      final schemaSeenBy = [
        (anthropic.sent.single['tools'] as List).single['input_schema'],
        (openAi.sent.single['tools'] as List).single['parameters'],
        (compatible.sent.single['tools'] as List).single['function']['parameters'],
      ];
      for (final schema in schemaSeenBy) {
        expect(schema, mealPhotoToolSchema);
      }
      final promptsSeenBy = [
        anthropic.sent.single['system'],
        openAi.sent.single['instructions'],
        (compatible.sent.single['messages'] as List).first['content'],
      ];
      expect(promptsSeenBy.toSet(), hasLength(1));
    });

    test('the schema asks for per-100 g macros on every component', () {
      final dish = (mealPhotoToolSchema['properties'] as Map)['dish'] as Map;
      final component =
          ((dish['properties'] as Map)['components'] as Map)['items'] as Map;
      expect(component['required'], containsAll(['query', 'grams', 'per_100g']));
      final per100 = (component['properties'] as Map)['per_100g'] as Map;
      expect(per100['required'], [
        'kcal',
        'protein_g',
        'carbs_g',
        'fat_g',
      ]);
    });

    test('absurd amounts are dropped while the food is kept', () async {
      final client = _ScriptedClient([
        (
          200,
          _anthropicReply(mealPhotoToolName, {
            'items': [
              _component('rice', 180),
              _component('soup', 0),
              _component('stew', 9000),
            ],
          }),
        ),
      ]);

      final items = (await _anthropic(client).interpret(_photo)).items;

      expect(items.map((i) => i.query), ['rice', 'soup', 'stew']);
      expect(items[0].quantity, 180);
      expect(items[0].estimated, isTrue);
      expect(items[1].quantity, isNull);
      expect(items[2].quantity, isNull);
    });

    test('the caption goes to the model with the image', () async {
      final client = _ScriptedClient([
        (200, _anthropicReply(mealPhotoToolName, _wrapReply)),
      ]);

      await _anthropic(client).interpret(
        _photo,
        caption: 'katsu chicken wrap from a cafe, ate half',
      );

      final blocks =
          (client.sent.single['messages'] as List).first['content'] as List;
      final text = blocks.firstWhere((b) => b['type'] == 'text')['text'];
      expect(text, contains('katsu chicken wrap from a cafe, ate half'));
      expect(text, startsWith(mealPhotoContentPrompt));
    });

    test('no caption leaves the prompt exactly as it was', () async {
      final client = _ScriptedClient([
        (200, _anthropicReply(mealPhotoToolName, _wrapReply)),
      ]);
      await _anthropic(client).interpret(_photo, caption: '   ');

      final blocks =
          (client.sent.single['messages'] as List).first['content'] as List;
      expect(
        blocks.firstWhere((b) => b['type'] == 'text')['text'],
        mealPhotoContentPrompt,
      );
    });

    test('an overlong caption is cut before it is sent', () async {
      final client = _ScriptedClient([
        (200, _anthropicReply(mealPhotoToolName, _wrapReply)),
      ]);
      await _anthropic(client).interpret(_photo, caption: 'x' * 1000);

      final blocks =
          (client.sent.single['messages'] as List).first['content'] as List;
      final text =
          blocks.firstWhere((b) => b['type'] == 'text')['text'] as String;
      expect(text.length, lessThan(mealPhotoCaptionMaxChars + 100));
    });

    test('an amount the caption states beats the estimate', () async {
      final client = _ScriptedClient([
        (200, _anthropicReply(mealPhotoToolName, _wrapReply)),
      ]);

      final result = await _anthropic(client).interpret(
        _photo,
        caption: 'katsu wrap with 200g chicken',
      );

      final chicken = result.dish!.components[1];
      expect(chicken.quantity, 200);
      expect(chicken.estimated, isFalse);
      expect(result.dish!.components[0].estimated, isTrue);
    });
  });

  group('a bad reply falls back to the counts-only reading', () {
    final itemsReply = _anthropicReply(mealItemsToolName, {
      'items': [
        {'query': 'egg', 'quantity': 2},
        {'query': 'rice', 'quantity': 200, 'unit': 'g'},
      ],
    });

    Future<(_ScriptedClient, MealTextParseResult)> readWith(
      String firstReply,
    ) async {
      final client = _ScriptedClient([(200, firstReply), (200, itemsReply)]);
      final result = await _anthropic(client).interpret(_photo);
      return (client, result);
    }

    void expectedFallback(_ScriptedClient client, MealTextParseResult result) {
      expect(client.sent, hasLength(2));
      expect(
        (client.sent.last['tools'] as List).single['name'],
        mealItemsToolName,
      );
      // The old rules, intact: the count survives, the measured rice does not.
      expect(result.dish, isNull);
      expect(result.items.map((i) => (i.query, i.quantity)), [
        ('egg', 2.0),
        ('rice', null),
      ]);
      expect(result.items.every((i) => !i.estimated), isTrue);
    }

    test('a dish without components', () async {
      final (client, result) = await readWith(
        _anthropicReply(mealPhotoToolName, {
          'dish': {'name': 'Wrap', 'components': []},
        }),
      );
      expectedFallback(client, result);
    });

    test('a component with no macros object', () async {
      final (client, result) = await readWith(
        _anthropicReply(mealPhotoToolName, {
          'items': [
            {'query': 'egg', 'grams': 100},
          ],
        }),
      );
      expectedFallback(client, result);
    });

    test('an input that is not an object', () async {
      final (client, result) = await readWith(
        jsonEncode({
          'content': [
            {'type': 'tool_use', 'name': mealPhotoToolName, 'input': 'oops'},
          ],
        }),
      );
      expectedFallback(client, result);
    });

    test('a body that will not decode', () async {
      final (client, result) = await readWith('<html>bad gateway</html>');
      expectedFallback(client, result);
    });

    test('arguments that are not JSON, on an OpenAI-shaped provider', () async {
      final client = _ScriptedClient([
        (
          200,
          jsonEncode({
            'choices': [
              {
                'message': {
                  'tool_calls': [
                    {
                      'function': {
                        'name': mealPhotoToolName,
                        'arguments': '{"dish": ',
                      },
                    },
                  ],
                },
              },
            ],
          }),
        ),
        (
          200,
          jsonEncode({
            'choices': [
              {
                'message': {
                  'tool_calls': [
                    {
                      'function': {
                        'name': mealItemsToolName,
                        'arguments': jsonEncode({
                          'items': [
                            {'query': 'egg', 'quantity': 2},
                          ],
                        }),
                      },
                    },
                  ],
                },
              },
            ],
          }),
        ),
      ]);

      final result = await ModelMealPhotoInterpreter(
        OpenAiCompatibleMealItemsApi.openRouter(client, () => 'k', model: 'm'),
      ).interpret(_photo);

      expect(client.sent, hasLength(2));
      expect(result.items.single.query, 'egg');
    });

    test('a client without the photo tool goes straight to it', () async {
      final client = _ScriptedClient([(200, itemsReply)]);
      final result = await ModelMealPhotoInterpreter(
        _ItemsOnly(AnthropicMealItemsApi(client, () => 'k')),
      ).interpret(_photo);

      expect(client.sent, hasLength(1));
      expect(result.items.map((i) => i.query), ['egg', 'rice']);
    });
  });

  group('failures a second request cannot change are not retried', () {
    for (final entry in {
      401: MealInterpreterFailure.auth,
      402: MealInterpreterFailure.billing,
      400: MealInterpreterFailure.rejected,
      404: MealInterpreterFailure.unsupported,
    }.entries) {
      test('${entry.key} surfaces as ${entry.value.name}, once', () async {
        final client = _ScriptedClient([(entry.key, '{}')]);

        await expectLater(
          _anthropic(client).interpret(_photo),
          throwsA(
            isA<MealInterpreterException>().having(
              (e) => e.failure,
              'failure',
              entry.value,
            ),
          ),
        );
        expect(client.sent, hasLength(1));
      });
    }

    test('a model that answers in prose is unsupported, once', () async {
      final client = _ScriptedClient([
        (200, jsonEncode({'content': [{'type': 'text', 'text': 'A wrap.'}]})),
      ]);

      await expectLater(
        _anthropic(client).interpret(_photo),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.failure,
            'failure',
            MealInterpreterFailure.unsupported,
          ),
        ),
      );
      expect(client.sent, hasLength(1));
    });
  });
}

class _ItemsOnly implements MealItemsApi {
  final MealItemsApi _inner;

  _ItemsOnly(this._inner);

  @override
  Future<MealTextParseResult> requestItems({
    required MealContent content,
    required String system,
  }) => _inner.requestItems(content: content, system: system);
}
