import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_interpreter_exception.dart';

void main() {
  group('providerErrorMessage', () {
    test('reads error.message, as OpenAI, Anthropic and OpenRouter send it', () {
      final body = jsonEncode({
        'error': {'message': 'Rate limit reached', 'code': 'rate_limit'},
      });

      expect(providerErrorMessage(body), 'Rate limit reached');
    });

    test('reads Google\'s message, which can arrive wrapped in a list', () {
      final body = jsonEncode([
        {
          'error': {
            'code': 400,
            'message': 'API key not valid. Please pass a valid API key.',
            'status': 'INVALID_ARGUMENT',
          },
        },
      ]);

      expect(
        providerErrorMessage(body),
        'API key not valid. Please pass a valid API key.',
      );
    });

    test('reads a string error and a bare message', () {
      expect(providerErrorMessage('{"error":"overloaded"}'), 'overloaded');
      expect(providerErrorMessage('{"message":"Forbidden"}'), 'Forbidden');
    });

    test('keeps a plain-text body, but never a page of HTML', () {
      expect(providerErrorMessage('upstream timed out'), 'upstream timed out');
      expect(providerErrorMessage('<html>502 Bad Gateway</html>'), isNull);
    });

    test('a JSON body with no message gives nothing, not the body', () {
      expect(providerErrorMessage('{"error":{"code":400}}'), isNull);
      expect(providerErrorMessage('{"detail":"x"}'), isNull);
      expect(providerErrorMessage('42'), isNull);
    });
  });

  group('sanitizeProviderMessage', () {
    test('cuts to 200 characters', () {
      final text = sanitizeProviderMessage('word ' * 100)!;

      expect(text.length, lessThanOrEqualTo(providerMessageMaxLength));
      expect(text, endsWith('…'));
    });

    test('collapses whitespace and gives null for nothing', () {
      expect(sanitizeProviderMessage('a \n\t b'), 'a b');
      expect(sanitizeProviderMessage('   '), isNull);
      expect(sanitizeProviderMessage(null), isNull);
    });

    test('masks an echoed, half-hidden key', () {
      final text = sanitizeProviderMessage(
        'Incorrect API key provided: sk-proj-****abcd. Find yours at x.',
      )!;

      expect(text, isNot(contains('sk-proj')));
      expect(text, isNot(contains('abcd')));
      expect(text, contains('Incorrect API key provided'));
    });

    test('masks a Google key in a URL and a bare AIza key', () {
      final text = sanitizeProviderMessage(
        'bad request to https://x.test/v1?key=SECRETVALUE123&alt=json and '
        'AIzaSyA1234567890abcdefghijk',
      )!;

      expect(text, isNot(contains('SECRETVALUE123')));
      expect(text, isNot(contains('AIzaSy')));
      expect(text, contains('alt=json'));
    });

    test('masks a bearer token and any long unbroken token', () {
      final text = sanitizeProviderMessage(
        'Authorization: Bearer abc.def-123 failed for '
        'gsk_0123456789abcdefghijklmnopqrstuv0123',
      )!;

      expect(text, isNot(contains('abc.def-123')));
      expect(text, isNot(contains('gsk_0123')));
    });

    test('leaves an ordinary sentence alone', () {
      const sentence = 'Please pass a valid API key. Quota exceeded for model.';

      expect(sanitizeProviderMessage(sentence), sentence);
    });
  });

  test('toString keeps the provider message out of logs', () {
    const e = MealInterpreterException(
      'provider returned 400',
      statusCode: 400,
      providerMessage: 'API key not valid',
    );

    expect(e.toString(), contains('status: 400'));
    expect(e.toString(), isNot(contains('API key not valid')));
  });
}
