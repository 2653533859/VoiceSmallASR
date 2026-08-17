/// 视频播放器字幕叠加样式。
library;

import 'package:flutter/material.dart';

enum SubtitlePosition { top, center, bottom }

extension SubtitlePositionLabels on SubtitlePosition {
  String get label {
    switch (this) {
      case SubtitlePosition.top:
        return '顶部';
      case SubtitlePosition.center:
        return '居中';
      case SubtitlePosition.bottom:
        return '底部';
    }
  }

  Alignment get alignment {
    switch (this) {
      case SubtitlePosition.top:
        return Alignment.topCenter;
      case SubtitlePosition.center:
        return Alignment.center;
      case SubtitlePosition.bottom:
        return Alignment.bottomCenter;
    }
  }
}

/// 可持久化的播放器字幕叠加配置。
class SubtitleStyle {
  const SubtitleStyle({
    this.fontSize = 18.0,
    this.textColor = 0xFFFFFFFF,
    this.backgroundColor = 0xC7000000,
    this.position = SubtitlePosition.bottom,
  });

  factory SubtitleStyle.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('subtitleStyle 必须是 JSON 对象');
    }
    final Object? rawFontSize = value['fontSize'];
    final Object? rawTextColor = value['textColor'];
    final Object? rawBackgroundColor = value['backgroundColor'];
    final Object? rawPosition = value['position'];
    final double? fontSize = rawFontSize is num ? rawFontSize.toDouble() : null;
    final int? textColor = _jsonColor(rawTextColor);
    final int? backgroundColor = _jsonColor(rawBackgroundColor);
    final SubtitlePosition? position = rawPosition is String
        ? SubtitlePosition.values.where((SubtitlePosition item) {
            return item.name == rawPosition;
          }).firstOrNull
        : null;
    if (fontSize == null ||
        !fontSize.isFinite ||
        fontSize < 12.0 ||
        fontSize > 48.0 ||
        textColor == null ||
        backgroundColor == null ||
        position == null) {
      throw const FormatException('subtitleStyle 包含无效值');
    }
    return SubtitleStyle(
      fontSize: fontSize,
      textColor: textColor,
      backgroundColor: backgroundColor,
      position: position,
    );
  }

  final double fontSize;
  final int textColor;
  final int backgroundColor;
  final SubtitlePosition position;

  Color get foreground => Color(textColor);

  Color get background => Color(backgroundColor);

  SubtitleStyle copyWith({
    double? fontSize,
    int? textColor,
    int? backgroundColor,
    SubtitlePosition? position,
  }) {
    return SubtitleStyle(
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      position: position ?? this.position,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'fontSize': fontSize,
    'textColor': textColor,
    'backgroundColor': backgroundColor,
    'position': position.name,
  };

  @override
  bool operator ==(Object other) {
    return other is SubtitleStyle &&
        other.fontSize == fontSize &&
        other.textColor == textColor &&
        other.backgroundColor == backgroundColor &&
        other.position == position;
  }

  @override
  int get hashCode =>
      Object.hash(fontSize, textColor, backgroundColor, position);
}

int? _jsonColor(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final int integer = value.toInt();
  return value == integer && integer >= 0 && integer <= 0xFFFFFFFF
      ? integer
      : null;
}
