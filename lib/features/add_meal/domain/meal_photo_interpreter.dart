import 'dart:typed_data';

import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

export 'package:opennutritracker/features/add_meal/domain/meal_interpreter_exception.dart';

/// A photo ready to send: the encoded bytes and the media type describing
/// them.
///
/// Bytes rather than a path, because this photo is never written to disk.
/// The user's own meal and recipe images are persisted by `UserImageStorage`
/// and belong to them; this one exists for the length of one HTTP request
/// and is then unreachable. Nothing in the app can show it again, which is
/// the property the settings disclosure promises.
class MealPhoto {
  final Uint8List bytes;

  /// One of the media types the provider accepts — `image/webp` in practice,
  /// since that is what the encoder produces.
  final String mediaType;

  const MealPhoto({required this.bytes, required this.mediaType});
}

/// Turns a photograph of a meal into items the existing food search can
/// resolve.
///
/// Returns the same [MealTextParseResult] the text interpreter and the
/// deterministic parser return, so the resolver, the review screen and the
/// write path do not know or care which of the three produced the items.
///
/// **An estimate is allowed only while it stays visibly an estimate.** The
/// text path can carry a quantity because the user *stated* one. A photograph
/// states nothing, so every amount it yields is flagged `estimated`, shown as
/// such on the review row and editable; an amount the user's caption states
/// wins. Per-100 g macros ride along for the "AI estimate" fallback only — a
/// database match that is good enough is never overridden by them. See
/// [ModelMealPhotoInterpreter], which enforces this rather than asking for it.
abstract interface class MealPhotoInterpreter {
  /// Interprets [photo], optionally hinted with the user's [localeCode] so
  /// food names come back in the language the search is querying.
  ///
  /// Raises [MealInterpreterException] for every ordinary failure. Unlike
  /// the text path there is nothing to fall back to — there is no offline
  /// parser for an image — so the caller shows the user what happened.
  ///
  /// [caption] is what the user typed about the photo, if anything. It goes to
  /// the model with the image, and any amount it states replaces the model's
  /// estimate for that food.
  Future<MealTextParseResult> interpret(
    MealPhoto photo, {
    String? localeCode,
    String? caption,
  });
}
