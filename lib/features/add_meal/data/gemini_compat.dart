/// What Google's OpenAI-compatible endpoint needs that the other
/// OpenAI-compatible destinations do not. Chosen by host, in one place, and
/// applied by `OpenAiCompatibleMealItemsApi` only when the address is Google's;
/// every other destination sends exactly what it always did.
library;

const geminiHost = 'generativelanguage.googleapis.com';

/// True when [endpoint] is Google's Generative Language API.
bool isGeminiEndpoint(Uri endpoint) => endpoint.host == geminiHost;

/// `reasoning_effort` for Gemini. Gemini 2.5 and 3 models think before they
/// answer by default, and Gemini 3 cannot switch it off; an extraction of two
/// foods does not need the default depth. `low` is accepted by every model that
/// accepts the field (`none` is refused by Gemini 3).
const geminiReasoningEffort = 'low';

/// Added to the answer budget for Gemini. Its `max_tokens` is
/// `maxOutputTokens`, which **includes thinking tokens**, so the 1024 the app
/// allows for a short list of short strings can be spent before the tool call
/// starts — a 200 with no tool call in it, which the app reads as a model that
/// cannot call tools.
const geminiThinkingAllowance = 8192;

/// Keys Google's endpoint is not sent, at any depth of a tool schema.
///
/// - `additionalProperties`: Gemini declares functions with an OpenAPI subset
///   of JSON Schema, and that subset has none.
/// - `maxItems`: with `tool_choice: "required"`, the photo schema's
///   `maxItems: 20` on a dish's ingredients makes Google answer 400 "Request
///   contains an invalid argument." for every photo; without it, 200 and a
///   tool call (measured on the app's own request, one key changed at a time:
///   ont-testdata `gemini_isolate.yml`, 30 Oct 2026). Every limit is dropped,
///   not only that one, so the next schema change cannot bring it back.
///
/// Both only restate what the Dart validators already enforce
/// (`mealPhotoEstimateFromJson` takes the same limits), so dropping them loses
/// nothing — the same stance the app takes towards provider-side strictness
/// everywhere.
const geminiDroppedSchemaKeys = {'additionalProperties', 'maxItems'};

/// [schema] without [geminiDroppedSchemaKeys], at every depth.
Map<String, Object?> geminiSchema(Map<String, Object?> schema) =>
    _strip(schema) as Map<String, Object?>;

Object? _strip(Object? node) => switch (node) {
  Map() => {
    for (final entry in node.entries)
      if (!geminiDroppedSchemaKeys.contains(entry.key))
        entry.key as String: _strip(entry.value),
  },
  List() => [for (final item in node) _strip(item)],
  _ => node,
};
