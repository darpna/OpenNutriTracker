import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/features/add_meal/data/gemini_compat.dart';
import 'package:opennutritracker/features/add_meal/data/openai_compatible_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';

class _Client extends http.BaseClient {
  final String body;
  Map<String, dynamic>? sent;

  _Client(this.body);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
    );
  }
}

String _toolReply(String name, Object arguments) => jsonEncode({
  'choices': [
    {
      'finish_reason': 'tool_calls',
      'message': {
        'tool_calls': [
          {
            'function': {'name': name, 'arguments': jsonEncode(arguments)},
          },
        ],
      },
    },
  ],
});

final _gemini = Uri.parse(
  'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
);
final _ollama = Uri.parse('http://192.168.1.5:11434/v1/chat/completions');

OpenAiCompatibleMealItemsApi _api(http.Client client, Uri endpoint) =>
    OpenAiCompatibleMealItemsApi(
      client,
      () => 'k',
      model: 'gemini-3.8-flash',
      endpoint: endpoint,
      toolChoice: ToolChoiceMode.anyTool,
    );

bool _hasKey(Object? node, String key) => switch (node) {
  Map() => node.containsKey(key) || node.values.any((v) => _hasKey(v, key)),
  List() => node.any((v) => _hasKey(v, key)),
  _ => false,
};

void main() {
  group('the host is recognised', () {
    test('Google\'s, and nobody else\'s', () {
      expect(isGeminiEndpoint(_gemini), isTrue);
      expect(isGeminiEndpoint(_ollama), isFalse);
      expect(
        isGeminiEndpoint(
          Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        ),
        isFalse,
      );
      expect(
        isGeminiEndpoint(
          Uri.parse('https://generativelanguage.googleapis.com.evil.example/x'),
        ),
        isFalse,
      );
    });
  });

  group('geminiSchema', () {
    test('removes the dropped keys at every depth and nothing else', () {
      final stripped = geminiSchema(mealPhotoToolSchema);

      for (final key in geminiDroppedSchemaKeys) {
        expect(_hasKey(mealPhotoToolSchema, key), isTrue, reason: key);
        expect(_hasKey(stripped, key), isFalse, reason: key);
      }
      expect(_hasKey(stripped, 'minItems'), isTrue);
      expect(stripped['required'], mealPhotoToolSchema['required']);
      final dishes = (stripped['properties'] as Map)['dishes'] as Map;
      final dish = dishes['items'] as Map;
      expect(dish['required'], [
        'name',
        'portion_g',
        'servings',
        'ingredients',
        'confidence',
        'assumptions',
      ]);
      final ingredient =
          ((dish['properties'] as Map)['ingredients'] as Map)['items'] as Map;
      expect(ingredient['required'], ['name', 'grams', 'per100g']);
    });

    test('leaves the shared constants untouched', () {
      geminiSchema(mealItemsToolSchema);
      expect(mealItemsToolSchema['additionalProperties'], isFalse);
    });

    test('the items schema keeps its enum and required list', () {
      final stripped = geminiSchema(mealItemsToolSchema);
      final item =
          ((stripped['properties'] as Map)['items'] as Map)['items'] as Map;
      expect(item['required'], ['query']);
      expect(
        ((item['properties'] as Map)['unit'] as Map)['enum'],
        contains('g'),
      );
    });
  });

  group('a request to Google', () {
    test(
      'drops additionalProperties, thinks little and has room to answer',
      () async {
        final client = _Client(
          _toolReply(mealItemsToolName, {
            'items': [
              {'query': 'egg', 'quantity': 2},
            ],
          }),
        );

        await _api(
          client,
          _gemini,
        ).requestItems(content: const MealTextContent('two eggs'), system: 's');

        final sent = client.sent!;
        expect(_hasKey(sent['tools'], 'additionalProperties'), isFalse);
        expect(sent['reasoning_effort'], 'low');
        expect(
          sent['max_tokens'],
          mealItemsToolSpec.maxTokens + geminiThinkingAllowance,
        );
        expect(sent['tool_choice'], 'required');
      },
    );

    test('the photo tool gets the same treatment', () async {
      final client = _Client(
        _toolReply(mealPhotoToolName, {'items': <Object?>[]}),
      );

      await _api(client, _gemini).requestPhotoToolInput(
        content: const MealPhotoContent(
          mediaType: 'image/jpeg',
          base64Data: 'AAAA',
        ),
        system: 's',
      );

      expect(_hasKey(client.sent!['tools'], 'additionalProperties'), isFalse);
      // maxItems with a forced tool call is what Google refused with a 400.
      expect(client.sent!['tool_choice'], 'required');
      expect(_hasKey(client.sent!['tools'], 'maxItems'), isFalse);
      expect(
        client.sent!['max_tokens'],
        mealPhotoToolSpec.maxTokens + geminiThinkingAllowance,
      );
    });
  });

  group('the override', () {
    test('false sends Google the request every other server gets', () async {
      final client = _Client(
        _toolReply(mealItemsToolName, {
          'items': [
            {'query': 'egg'},
          ],
        }),
      );
      final api = OpenAiCompatibleMealItemsApi(
        client,
        () => 'k',
        model: 'm',
        endpoint: _gemini,
        toolChoice: ToolChoiceMode.anyTool,
        geminiCompat: false,
      );

      await api.requestItems(
        content: const MealTextContent('egg'),
        system: 's',
      );

      expect(client.sent!.containsKey('reasoning_effort'), isFalse);
      expect(client.sent!['max_tokens'], mealItemsToolSpec.maxTokens);
      expect(
        (client.sent!['tools'] as List).single['function']['parameters'],
        mealItemsToolSchema,
      );
    });
  });

  group('every other destination is unchanged', () {
    for (final endpoint in [
      _ollama,
      Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
    ]) {
      test(endpoint.host, () async {
        final client = _Client(
          _toolReply(mealItemsToolName, {
            'items': [
              {'query': 'egg'},
            ],
          }),
        );

        await _api(
          client,
          endpoint,
        ).requestItems(content: const MealTextContent('egg'), system: 's');

        final sent = client.sent!;
        expect(sent.containsKey('reasoning_effort'), isFalse);
        expect(sent['max_tokens'], mealItemsToolSpec.maxTokens);
        expect(
          (sent['tools'] as List).single['function']['parameters'],
          mealItemsToolSchema,
        );
      });
    }
  });

  group('a reply cut off by the answer budget', () {
    String cutOff({Object? toolCalls}) => jsonEncode({
      'choices': [
        {
          'finish_reason': 'length',
          'message': {
            'role': 'assistant',
            'content': null,
            'tool_calls': toolCalls,
          },
        },
      ],
    });

    for (final calls in [null, <Object?>[]]) {
      test(
        'with tool_calls ${calls ?? 'absent'} is transient, not unsupported',
        () async {
          final client = _Client(cutOff(toolCalls: calls));

          await expectLater(
            _api(client, _gemini).requestItems(
              content: const MealTextContent('two eggs'),
              system: 's',
            ),
            throwsA(
              isA<MealInterpreterException>()
                  .having(
                    (e) => e.failure,
                    'failure',
                    MealInterpreterFailure.transient,
                  )
                  .having((e) => e.reason, 'reason', contains('cut off')),
            ),
          );
        },
      );
    }

    test('prose that simply ended is still unsupported', () async {
      final client = _Client(
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {'role': 'assistant', 'content': 'Two eggs.'},
            },
          ],
        }),
      );

      await expectLater(
        _api(
          client,
          _gemini,
        ).requestItems(content: const MealTextContent('two eggs'), system: 's'),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.failure,
            'failure',
            MealInterpreterFailure.unsupported,
          ),
        ),
      );
    });
  });
}
