import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mi_virtual_background_kit_platform_interface.dart';

/// An implementation of [MiVirtualBackgroundKitPlatform] that uses method channels.
class MethodChannelMiVirtualBackgroundKit extends MiVirtualBackgroundKitPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('mi_virtual_background_kit');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
