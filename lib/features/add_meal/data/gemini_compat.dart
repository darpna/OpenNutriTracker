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

/// [schema] without `additionalProperties`, at every depth.
///
/// Gemini declares functions with an OpenAPI subset of JSON Schema, and that
/// subset has no `additionalProperties`. Here it only restates what the Dart
/// validators already enforce, so dropping it loses nothing — the same
/// stance the app takes towards provider-side strictness everywhere.
Map<String, Object?> withoutAdditionalProperties(Map<String, Object?> schema) =>
    _strip(schema) as Map<String, Object?>;

Object? _strip(Object? node) => switch (node) {
  Map() => {
    for (final entry in node.entries)
      if (entry.key != 'additionalProperties')
        entry.key as String: _strip(entry.value),
  },
  List() => [for (final item in node) _strip(item)],
  _ => node,
};
