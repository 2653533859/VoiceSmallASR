/// 第三方翻译服务的数据发送提示。
library;

import 'package:flutter/material.dart';

/// 在第一次使用在线翻译前明确告知用户字幕会离开本机。
Future<bool> confirmThirdPartyTranslation(BuildContext context) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('发送字幕到第三方服务？'),
      content: const Text(
        '翻译时，字幕文本会发送到你配置的第三方翻译服务。请确认你已了解并接受该服务商的隐私政策和数据处理方式。',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('继续翻译'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
