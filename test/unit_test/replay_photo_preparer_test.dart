import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../tool/replay/dart_photo_preparer.dart';

void main() {
  const preparer = DartPhotoPreparer();

  Uint8List jpeg(int width, int height) => Uint8List.fromList(
    img.encodeJpg(img.Image(width: width, height: height)),
  );

  test('scales the shortest edge down to 1024 and sends a JPEG', () {
    final photo = preparer.encodeBytes(jpeg(4000, 3000))!;

    expect(photo.mediaType, 'image/jpeg');
    final out = img.decodeJpg(photo.bytes)!;
    expect(out.height, 1024);
    expect(out.width, closeTo(1365, 1));
  });

  test('works the same on a portrait photo', () {
    final out = img.decodeJpg(preparer.encodeBytes(jpeg(3000, 4000))!.bytes)!;
    expect(out.width, 1024);
    expect(out.height, closeTo(1365, 1));
  });

  test('never enlarges a small photo', () {
    final out = img.decodeJpg(preparer.encodeBytes(jpeg(600, 400))!.bytes)!;
    expect((out.width, out.height), (600, 400));
  });

  test('the result carries no EXIF block', () {
    final image = img.Image(width: 800, height: 800)
      ..exif.imageIfd.orientation = 6
      ..exif.gpsIfd.gpsLatitude = 46.9;
    final photo = preparer.encodeBytes(
      Uint8List.fromList(img.encodeJpg(image)),
    )!;

    final decoded = img.decodeJpg(photo.bytes)!;
    expect(decoded.exif.isEmpty, isTrue);
  });

  test('bytes that are not an image are refused, not guessed at', () {
    expect(preparer.encodeBytes(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });
}
