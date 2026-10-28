// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'custom_portion_dbo.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CustomPortionDBOAdapter extends TypeAdapter<CustomPortionDBO> {
  @override
  final typeId = 24;

  @override
  CustomPortionDBO read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CustomPortionDBO(
      id: fields[0] as String,
      foodKey: fields[1] as String,
      label: fields[2] as String,
      gramWeight: (fields[3] as num).toDouble(),
      unit: fields[4] == null ? 'g' : fields[4] as String,
      createdAt: fields[5] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, CustomPortionDBO obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.foodKey)
      ..writeByte(2)
      ..write(obj.label)
      ..writeByte(3)
      ..write(obj.gramWeight)
      ..writeByte(4)
      ..write(obj.unit)
      ..writeByte(5)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomPortionDBOAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

CustomPortionDBO _$CustomPortionDBOFromJson(Map<String, dynamic> json) =>
    CustomPortionDBO(
      id: json['id'] as String,
      foodKey: json['foodKey'] as String,
      label: json['label'] as String,
      gramWeight: (json['gramWeight'] as num).toDouble(),
      unit: json['unit'] as String? ?? 'g',
      createdAt: DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$CustomPortionDBOToJson(CustomPortionDBO instance) =>
    <String, dynamic>{
      'id': instance.id,
      'foodKey': instance.foodKey,
      'label': instance.label,
      'gramWeight': instance.gramWeight,
      'unit': instance.unit,
      'createdAt': instance.createdAt.toIso8601String(),
    };
