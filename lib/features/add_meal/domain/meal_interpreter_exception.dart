import 'dart:convert';

/// What a caller can usefully do about a failed interpretation.
///
/// Provider-neutral on purpose. The same HTTP status means different things
/// to different providers — 404 is a capability refusal on a broker that
/// could not find an endpoint, and merely a wrong URL somewhere else — so
/// the mapping from status to meaning belongs in each client, where the
/// evidence for it lives. Callers switch on the meaning and never see the
/// number.
enum MealInterpreterFailure {
  /// A retry might survive this: no network, a rate limit, a 5xx, a reply
  /// that did not parse. The default, because anything unrecognised is
  /// better offered as retryable than declared permanent.
  transient,

  /// The provider rejected the credential itself. Shown differently from a
  /// transient failure: telling someone to "try again later" when their key
  /// is wrong is the puzzle [AiCredentialStorage] already goes out of its
  /// way to avoid.
  auth,

  /// The provider rejected the request rather than failing to serve it. On
  /// the photo path that means the image.
  rejected,

  /// Nothing on the other end can serve this kind of request at all — the
  /// chosen model takes no images, or no provider of it honours a forced
  /// tool call. Points the user at their settings, not at their network.
  unsupported,

  /// The account cannot pay: no credit, or a spend cap reached.
  ///
  /// Its own meaning because both of the alternatives are actively wrong.
  /// [transient] tells someone to retry, which is a loop with no exit —
  /// OpenRouter states that retrying "billing, spend, or quota errors won't
  /// restore API access". [auth] sends them to check a key that works, which
  /// is exactly the misdirection this vocabulary exists to prevent.
  ///
  /// Both shipped providers answer **402** for it and **429** for an
  /// ordinary rate limit, so the two are separable on status alone with no
  /// body parsing.
  billing,

  /// The destination did not answer inside the budget the client allowed.
  ///
  /// Told apart from [transient] because they are different facts about
  /// different things. A transient failure is the *connection* — dropped,
  /// rate limited, refused — and checking the network is sensible advice for
  /// it. This one is the *server*: the connection worked, the request
  /// arrived, and the answer was still not finished when the client stopped
  /// waiting. Advice about a network fixes nothing.
  ///
  /// **Which destinations use it is a per-client policy, not a property of
  /// timing out** — see `OpenAiCompatibleMealItemsApi.timeoutFailure`. A
  /// hosted API that misses a 20s budget really has had a blip and really
  /// should be retried, so those clients keep reporting [transient]. A
  /// machine in the user's house that misses a 120s budget has told them
  /// something durable about that machine (#774).
  timeout,

  /// The request was **not sent**: it was plaintext, and the address it
  /// resolved to is not private.
  ///
  /// The only member that describes something the app did rather than
  /// something a provider answered, and it has to be told apart from
  /// [transient] for the usual reason: nothing is wrong with the network,
  /// and checking it will not help. The fix is in settings — `https://`, or
  /// an address on the user's own network.
  ///
  /// It exists because #746 and #748 measured that **neither platform blocks
  /// cleartext for this app's stack**: `dart:io` is BSD sockets rather than
  /// NSURLSession, so ATS and Android's cleartext policy never see these
  /// requests. Nothing outside the app enforces this, which makes this
  /// refusal the whole of the enforcement rather than a second line of it.
  insecureDestination,
}

/// Raised when an interpreter cannot produce a result. Carries no response
/// body: provider payloads can echo the submitted text, and this ends up in
/// logs. The one thing taken from a refused request's body is its error text,
/// capped and with key-shaped strings masked ([providerMessage]).
///
/// Shared by the text and photo interpreters. The two differ in what the
/// caller does about it — a failed text read falls back to the deterministic
/// parser, a failed photo read has nothing to fall back to and must be shown
/// — but the failures themselves are the same handful of things: no network,
/// a rejected key, a rate limit, a malformed reply.
class MealInterpreterException implements Exception {
  final String reason;

  /// What the caller should do about it, decided by the client that threw.
  ///
  /// Defaults to [MealInterpreterFailure.transient] so a failure with no
  /// status behind it — a socket error, a reply that did not parse — stays
  /// retryable without every throw site having to say so.
  final MealInterpreterFailure failure;

  /// The provider's HTTP status, when there was one. **Diagnostic only.**
  ///
  /// Nothing decides anything from this: a raw number is what a reader of a
  /// log wants, and what a caller must not have, because interpreting it
  /// correctly needs to know which provider answered.
  final int? statusCode;

  /// What the provider said about a refused request, from its error body:
  /// trimmed, with anything key-shaped masked (see [providerErrorMessage]).
  /// Null when it said nothing readable.
  ///
  /// **For people, never for decisions.** It exists so a wrong key, a rate
  /// limit and a bad photo stop looking alike once they reach a screen or a
  /// replay file. Only the error text is kept, never the rest of the body.
  final String? providerMessage;

  /// True when the provider answered 200 and what came back was not the shape
  /// asked for — a body that will not decode, a tool call with no usable
  /// arguments. The one failure the photo interpreter answers by asking again
  /// the old, simpler way (see `ModelMealPhotoInterpreter`); every other kind
  /// says something about the account, the network or the model's abilities
  /// that a second request cannot change.
  final bool badReply;

  const MealInterpreterException(
    this.reason, {
    this.failure = MealInterpreterFailure.transient,
    this.statusCode,
    this.providerMessage,
    this.badReply = false,
  });

  const MealInterpreterException.badReply(this.reason)
    : failure = MealInterpreterFailure.transient,
      statusCode = null,
      providerMessage = null,
      badReply = true;

  @override
  String toString() =>
      'MealInterpreterException($reason, ${failure.name}'
      '${statusCode == null ? '' : ', status: $statusCode'})';
}

/// The longest provider message kept, in characters.
const providerMessageMaxLength = 200;

final _bearerToken = RegExp(r'\b(Bearer|Basic)\s+\S+', caseSensitive: false);
final _keyQueryParam = RegExp(
  r'''([?&;](?:api[_-]?)?key=)[^&\s"']+''',
  caseSensitive: false,
);
// A provider's own key prefix, including the half-hidden form some providers
// echo back ("sk-proj-********abcd").
final _prefixedKey = RegExp(
  r'\b(?:sk|gsk|xai|pk|rk|AIza|ghp|hf)[-_][A-Za-z0-9_*\-]{6,}|\bAIza[A-Za-z0-9_\-]{10,}',
);
// Anything else that is one long unbroken token is more likely a secret than
// a word.
final _longToken = RegExp(r'[A-Za-z0-9_\-]{24,}');

/// [raw] made safe to show: whitespace collapsed, anything that looks like an
/// API key or bearer token replaced with `***`, cut to
/// [providerMessageMaxLength]. Null when nothing is left.
String? sanitizeProviderMessage(String? raw) {
  if (raw == null) return null;
  var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text
      .replaceAllMapped(_bearerToken, (m) => '${m[1]} ***')
      .replaceAllMapped(_keyQueryParam, (m) => '${m[1]}***')
      .replaceAll(_prefixedKey, '***')
      .replaceAll(_longToken, '***');
  if (text.isEmpty) return null;
  if (text.length > providerMessageMaxLength) {
    text = '${text.substring(0, providerMessageMaxLength - 1).trimRight()}…';
  }
  return text;
}

/// The human-readable error text in a provider's non-2xx [body], sanitised by
/// [sanitizeProviderMessage]. Reads the `error.message` shape OpenAI,
/// Anthropic, Google and OpenRouter all use (Google sometimes wraps it in a
/// one-element list), a bare `message`, or a plain-text body. A JSON body with
/// no message, and HTML, give null rather than a dump of the page.
String? providerErrorMessage(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    final plain = body.trim();
    return plain.startsWith('<') ? null : sanitizeProviderMessage(plain);
  }
  final root = decoded is List && decoded.isNotEmpty ? decoded.first : decoded;
  if (root is! Map) return null;
  final error = root['error'];
  final message = error is Map
      ? error['message']
      : error is String
      ? error
      : root['message'];
  return message is String ? sanitizeProviderMessage(message) : null;
}
