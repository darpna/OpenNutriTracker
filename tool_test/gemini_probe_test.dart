// A diagnostic, not a unit test: it asks Google's OpenAI-compatible endpoint
// the questions the app's setup check asks, through the real client, schema,
// prompts and validators, and prints everything needed to see why an answer
// came back empty. Lives outside test/ so `flutter test` never runs it; the
// `Darp Gemini probe` workflow does. Needs GEMINI_API_KEY; without it the test
// says so and skips.
//
//   GEMINI_API_KEY=… GEMINI_MODEL=gemini-3.8-flash PROBE_MODE=both \
//     flutter test tool_test/gemini_probe_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/data/meal_items_api_factory.dart';
import 'package:opennutritracker/features/add_meal/data/openai_compatible_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/data/model_meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/data/model_meal_text_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/probe_ai_endpoint_usecase.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

/// The base address as a user would type it, which the app completes to the
/// chat route.
const _typedAddress =
    'https://generativelanguage.googleapis.com/v1beta/openai/';

/// `baseline` sends what the app sent before the Gemini fix (the client with
/// Google's compatibility handling switched off); `fixed` sends what it sends
/// now.
final _variant = Platform.environment['PROBE_VARIANT'] ?? 'fixed';

final _key = Platform.environment['GEMINI_API_KEY'] ?? '';
final _model = Platform.environment['GEMINI_MODEL'] ?? 'gemini-3.8-flash';
final _mode = Platform.environment['PROBE_MODE'] ?? 'both';

/// Records every exchange with the key and the image bytes taken out.
class _LoggingClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final lines = <String>[];

  String _redact(String text) {
    var out = _key.isEmpty ? text : text.replaceAll(_key, '***');
    out = out.replaceAllMapped(
      RegExp(r'data:[a-z/+]+;base64,[A-Za-z0-9+/=]+'),
      (m) =>
          '${m.group(0)!.substring(0, m.group(0)!.indexOf(',') + 1)}'
          '<${m.group(0)!.length} chars>',
    );
    return out;
  }

  void _say(String text) {
    final redacted = _redact(text);
    lines.add(redacted);
    // ignore: avoid_print
    print(redacted);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    _say('--- REQUEST ${request.method} ${request.url}');
    _say('headers: ${request.headers.keys.toList()} (values withheld)');
    try {
      _say(const JsonEncoder.withIndent('  ').convert(jsonDecode(body)));
    } catch (_) {
      _say(body);
    }
    final response = await _inner.send(request);
    final bytes = await response.stream.toBytes();
    _say('--- RESPONSE status ${response.statusCode}');
    _say(utf8.decode(bytes, allowMalformed: true));
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      request: request,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }
}

void _describe(String label, MealTextParseResult result) {
  // ignore: avoid_print
  print(
    '=== $label: ${result.items.length} item(s), '
    '${result.errors.length} refused',
  );
  for (final item in result.items) {
    // ignore: avoid_print
    print('  kept: $item');
  }
  for (final error in result.errors) {
    // ignore: avoid_print
    print('  refused: $error');
  }
  final dish = result.dish;
  if (dish != null) {
    // ignore: avoid_print
    print('  dish: ${dish.name}');
    for (final part in dish.components) {
      // ignore: avoid_print
      print('    part: $part');
    }
  }
}

void main() {
  final skip = _key.isEmpty
      ? 'GEMINI_API_KEY is not set: add it as a repository secret to run this '
            'probe'
      : null;
  if (skip != null) {
    // ignore: avoid_print
    print('SKIPPED: $skip');
  }

  late AiSelection selection;
  late _LoggingClient client;

  setUp(() {
    final endpoint = AiCredentialStorage.resolveEndpoint(_typedAddress)!;
    // ignore: avoid_print
    print(
      'variant $_variant: typed $_typedAddress -> requested as $endpoint, '
      'model $_model',
    );
    selection = AiSelection(
      provider: AiProvider.ownServer,
      apiKey: _key,
      endpoint: endpoint.toString(),
      modelId: _model,
    );
    client = _LoggingClient();
  });

  Future<MealPhoto> sample() async => MealPhoto(
    // The bundled loaf-of-bread photograph the app's own setup check sends.
    bytes: await File(aiProbePhotoAsset).readAsBytes(),
    mediaType: 'image/jpeg',
  );

  /// What the app builds for this selection, or — for `baseline` — the same
  /// client without Google's compatibility handling, which is exactly what the
  /// app sent before the fix.
  MealItemsApi buildApi(http.Client http, AiSelection selection) {
    if (_variant != 'baseline') {
      return mealItemsApiFor(http, selection, timeout: aiEndpointProbeTimeout);
    }
    return OpenAiCompatibleMealItemsApi(
      http,
      () => selection.apiKey ?? '',
      model: selection.modelId!,
      endpoint: Uri.parse(selection.endpoint!),
      toolChoice: ToolChoiceMode.anyTool,
      timeout: aiEndpointProbeTimeout,
      timeoutFailure: MealInterpreterFailure.timeout,
      geminiCompat: false,
    );
  }

  /// Google answers 503 "high demand" and stalls on busy models, which the
  /// probe reads as `unknown`. A diagnostic retries those; a verdict of
  /// `failed` is never retried, because that is the answer being looked for.
  Future<AiCapability> verdictOf(
    String label,
    Future<AiCapability> Function() probe,
  ) async {
    var verdict = await probe();
    for (
      var attempt = 2;
      attempt <= 3 && verdict == AiCapability.unknown;
      attempt++
    ) {
      // ignore: avoid_print
      print('=== $label verdict: unknown; trying again ($attempt of 3)');
      await Future<void>.delayed(const Duration(seconds: 15));
      verdict = await probe();
    }
    // ignore: avoid_print
    print('=== $label verdict: ${verdict.name}');
    return verdict;
  }

  test(
    'text: the setup check, then the detail',
    () async {
      if (_mode == 'photo') return;
      final prober = AiEndpointProber(
        client,
        sampleImage: (_) async => null,
        apiFor: buildApi,
      );
      final verdict = await verdictOf(
        'text',
        () => prober.probeText(selection),
      );

      try {
        _describe(
          'text interpreter',
          await ModelMealTextInterpreter(
            buildApi(client, selection),
          ).interpret(aiProbeMealLine),
        );
      } on MealInterpreterException catch (e) {
        // ignore: avoid_print
        print('=== text interpreter threw: $e');
      }
      // The baseline is the bug being reproduced; it is reported, not asserted.
      if (_variant != 'baseline') expect(verdict, AiCapability.passed);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'photo: the setup check, then the detail',
    () async {
      if (_mode == 'text') return;
      final photo = await sample();
      final prober = AiEndpointProber(
        client,
        sampleImage: (_) async => photo,
        apiFor: buildApi,
      );
      final verdict = await verdictOf(
        'photo',
        () => prober.probePhoto(selection),
      );

      try {
        _describe(
          'photo interpreter',
          await ModelMealPhotoInterpreter(
            buildApi(client, selection),
          ).interpret(photo),
        );
      } on MealInterpreterException catch (e) {
        // ignore: avoid_print
        print('=== photo interpreter threw: $e');
      }
      if (_variant != 'baseline') expect(verdict, AiCapability.passed);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
