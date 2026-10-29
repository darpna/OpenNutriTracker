import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/util/meal_photo_encoder.dart';
import 'package:opennutritracker/features/add_meal/util/meal_photo_preparer.dart';

/// The app's photo encoding without the native encoder, for a machine that has
/// none.
///
/// The app uses `flutter_image_compress`, a platform plugin that does not exist
/// under `flutter test` or `dart run`. This does the same job in Dart: apply the
/// photo's EXIF orientation, scale so the shortest edge is 1024 px (never
/// enlarging), and re-encode as JPEG at quality 80, which for a server the user
/// runs is the format the app sends. Re-encoding writes a container with no
/// metadata, as it does in the app. The pixels differ slightly from the native
/// encoder's; size, format and quality are the same, which is what the model
/// sees.
///
/// Nothing is written to disk and the source file is not touched: the replay
/// reads photos from a folder it does not own.
/// The app's own ceiling on what it sends (`MealPhotoEncoder.maxBytes`).
const _maxBytes = 3 * 1024 * 1024;

class DartPhotoPreparer extends MealPhotoPreparer {
  const DartPhotoPreparer();

  @override
  Future<MealPhoto?> prepare(String sourcePath, MealPhotoFormat format) async {
    return encodeBytes(await File(sourcePath).readAsBytes());
  }

  /// Encodes [bytes], or null when they are not an image this can read or the
  /// result would be too large to send.
  MealPhoto? encodeBytes(Uint8List bytes) {
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      return null;
    }
    if (decoded == null) return null;
    var image = img.bakeOrientation(decoded);
    // The encoder writes whatever EXIF the image carries, GPS included; the
    // app's encoder writes none.
    image.exif = img.ExifData();
    final shortest = image.width < image.height ? image.width : image.height;
    if (shortest > 1024) {
      final scale = 1024 / shortest;
      image = img.copyResize(
        image,
        width: (image.width * scale).round(),
        height: (image.height * scale).round(),
        interpolation: img.Interpolation.average,
      );
    }
    final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 80));
    if (jpeg.isEmpty || jpeg.length > _maxBytes) return null;
    return MealPhoto(bytes: jpeg, mediaType: 'image/jpeg');
  }
}
