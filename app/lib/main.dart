import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vsasr_app/src/ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const VsasrApp());
}
