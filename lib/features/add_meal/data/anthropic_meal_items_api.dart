import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

/// Asks Claude directly, over the Messages API, for a list of food items.
///
/// One of two [MealItemsApi] implementations. This one holds nothing but
/// Anthropic's wire format: the prompts, the counts-only rule and
/// [mealItemsToolSchema] live above the seam, shared with every provider.
class AnthropicMealItemsApi implements MealItemsApi, MealPhotoToolApi {
  static final _log = Logger('AnthropicMealItemsApi');

  static const _endpoint = 'https://api.anthropic.com/v1/messages';

  /// Pinned rather than tracking "latest": a silent model change would move
  /// behaviour the user never asked to change, and these calls are cheap
  /// enough that the smallest current model is the right default. Haiku 4.5
  /// takes images as well as text, so both paths share it.
  static const defaultModel = 'claude-haiku-4-5';

  /// The API version header Anthropic requires. Pinned for the same reason.
  static const _apiVersion = '2023-06-01';

  /// Matches the other remote data sources in this repo. Without it a
  /// stalled connection hangs until the OS gives up, which means the user
  /// waits instead of being told, or falling back to the parser.
  static const defaultTimeout = Duration(seconds: 20);

  final http.Client _client;
  final String Function() _apiKey;
  final String model;

  /// Injectable so the stalled-connection tests do not spend the real twenty
  /// seconds proving it. Raising the production value should not quietly
  /// make the suite slower.
  final Duration timeout;

  AnthropicMealItemsApi(
    this._client,
    this._apiKey, {
    this.model = defaultModel,
    this.timeout = defaultTimeout,
  });

  /// Sends one forced tool call and returns the validated items.
  @override
  Future<MealTextParseResult> requestItems({
    required MealContent content,
    required String system,
  }) async {
    final input = await _callTool(mealItemsToolSpec, content, system);
    return validateParsedMealItems(
      mealItemsFromJson(input is Map ? input['items'] : null),
      // Only the typed path corroborates: a photograph states no units at
      // all, and its own counts-only filter already drops them.
      statedIn: content is MealTextContent ? content.text : null,
    );
  }

  /// The photo tool's raw input; `mealPhotoResultFromJson` validates it.
  @override
  Future<Object?> requestPhotoToolInput({
    required MealPhotoContent content,
    required String system,
  }) => _callTool(mealPhotoToolSpec, content, system);

  /// One forced call to [spec], returning the tool's input untouched.
  ///
  /// `max_tokens` is per tool and small on purpose: a list of short strings
  /// needs little, and a large budget only buys a longer runaway before it is
  /// cut off. The photo tool carries macros per component and gets more.
  Future<Object?> _callTool(
    MealToolSpec spec,
    MealContent content,
    String system,
  ) async {
    final body = jsonEncode({
      'model': model,
      'max_tokens': spec.maxTokens,
      'system': system,
      'tools': [
        {
          'name': spec.name,
          'description': spec.description,
          'input_schema': spec.schema,
        },
      ],
      // Forcing the tool is what makes the reply parseable. Without it the
      // model may answer in prose and every caller needs a fallback parser.
      'tool_choice': {'type': 'tool', 'name': spec.name},
      'messages': [
        {'role': 'user', 'content': _contentJson(content)},
      ],
    });

    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(_endpoint),
            headers: {
              'content-type': 'application/json',
              'x-api-key': _apiKey(),
              'anthropic-version': _apiVersion,
            },
            body: body,
          )
          .timeout(timeout);
    } catch (e) {
      // Deliberately not logging `e`: a socket error can carry the request
      // URL and, on some platforms, part of the payload — which for the
      // photo path is the photograph.
      throw const MealInterpreterException('request failed');
    }

    if (response.statusCode != 200) {
      _log.warning('Interpreter call failed with ${response.statusCode}');
      throw MealInterpreterException(
        'provider returned ${response.statusCode}',
        failure: _failureFor(response.statusCode),
        statusCode: response.statusCode,
      );
    }

    return _toolInputFrom(response.body, spec.name);
  }

  /// What Anthropic's status codes mean here.
  ///
  /// Lives in this client rather than on [MealInterpreterException] because
  /// the same number does not mean the same thing to every provider, and a
  /// shared reading of it would have to be right for all of them at once.
  ///
  /// **400 was measured, not assumed.** Running a corpus of real photographs
  /// found that JPEGs carrying Adobe APP14 markers were refused with a 400
  /// on every attempt, while the same picture re-encoded went through.
  /// Retrying one of those never succeeds, so it must not be offered to the
  /// user as retryable.
  ///
  /// 404 is kept as a capability refusal so this move changes no behaviour,
  /// but it is not reachable on this path: the direct client's model is
  /// pinned and takes images. A broker can be pointed at a model that does
  /// not, which is where that case actually comes from.
  static MealInterpreterFailure _failureFor(int statusCode) =>
      switch (statusCode) {
        // 403 is `permission_error` here — "your API key does not have
        // permission" — so it genuinely belongs with 401. That is *not* true
        // of every provider, which is why this switch is per client.
        401 || 403 => MealInterpreterFailure.auth,
        400 || 422 => MealInterpreterFailure.rejected,
        // `billing_error`. Distinct from the 429 below, which is
        // `rate_limit_error` — going too fast, not unable to pay.
        402 => MealInterpreterFailure.billing,
        404 => MealInterpreterFailure.unsupported,
        _ => MealInterpreterFailure.transient,
      };

  /// Anthropic's message content. **Image before text**, which is what
  /// Anthropic's own vision guidance recommends — and the opposite of what
  /// OpenRouter recommends, which is why this rendering is per-client rather
  /// than on [MealContent].
  Object _contentJson(MealContent content) => switch (content) {
    MealTextContent(:final text) => text,
    final MealPhotoContent photo => [
      {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': photo.mediaType,
          'data': photo.base64Data,
        },
      },
      {'type': 'text', 'text': mealPhotoPromptText(photo)},
    ],
  };

  /// Pulls the tool input out of the reply. Every shape that is not the one
  /// expected raises rather than guessing, so a changed API surfaces as a
  /// handled failure instead of silent nonsense.
  Object? _toolInputFrom(String responseBody, String toolName) {
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(responseBody) as Map<String, dynamic>;
    } catch (_) {
      throw const MealInterpreterException.badReply('malformed response');
    }

    final content = decoded['content'];
    if (content is! List) {
      throw const MealInterpreterException.badReply('response has no content');
    }

    for (final block in content) {
      if (block is! Map) continue;
      if (block['type'] != 'tool_use') continue;
      if (block['name'] != toolName) continue;

      // Returned unchecked: each reader (`mealItemsFromJson`,
      // `mealPhotoResultFromJson`) checks the shape itself, so a provider
      // returning something other than an object ends in a handled failure
      // rather than a TypeError past the exception surface the callers rely
      // on.
      return block['input'];
    }

    throw MealInterpreterException(
      'response has no tool call',
      // Not the default `transient`, which would send the user to check a
      // connection that just delivered a 200. A model that will not call the
      // tool will not call it next time either, and `unsupported` already
      // names exactly this: "no provider of it honours a forced tool call".
      // Ollama has no `tool_choice` field at all (#733), so on the most
      // popular local runtime this is the expected failure rather than a
      // rare one, and #779's probe has to be able to tell it from a blip.
      failure: MealInterpreterFailure.unsupported,
    );
  }
}
