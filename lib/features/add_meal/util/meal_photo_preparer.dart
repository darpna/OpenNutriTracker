import 'dart:io';
import 'dart:typed_data';

import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/util/meal_photo_encoder.dart';

/// Turns a file the image picker wrote into the photo to send, and discards
/// that file.
///
/// A thin seam over [MealPhotoEncoder.encodeAndDiscardSource] so the bulk-add
/// screen can start the work the moment a photo is picked and a test can
/// control when it finishes. The cache-copy deletion is the encoder's and is
/// unchanged: it runs whether or not the encode succeeded, and so whether or
/// not the user went on to use the photo.
class MealPhotoPreparer {
  const MealPhotoPreparer();

  /// The picked file's bytes for the thumbnail, or null when it cannot be
  /// read. Read before [prepare] starts, because [prepare] deletes the file.
  Future<Uint8List?> thumbnail(String sourcePath) async {
    try {
      return await File(sourcePath).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<MealPhoto?> prepare(String sourcePath, MealPhotoFormat format) =>
      MealPhotoEncoder.encodeAndDiscardSource(sourcePath, format: format);
}
