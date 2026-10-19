import 'dart:io' show Platform;

String? environmentValue(String name) => Platform.environment[name];
