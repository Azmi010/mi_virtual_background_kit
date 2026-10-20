import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'mi_virtual_background_kit_method_channel.dart';

abstract class MiVirtualBackgroundKitPlatform extends PlatformInterface {
  /// Constructs a MiVirtualBackgroundKitPlatform.
  MiVirtualBackgroundKitPlatform() : super(token: _token);

  static final Object _token = Object();

  static MiVirtualBackgroundKitPlatform _instance = MethodChannelMiVirtualBackgroundKit();

  /// The default instance of [MiVirtualBackgroundKitPlatform] to use.
  ///
  /// Defaults to [MethodChannelMiVirtualBackgroundKit].
  static MiVirtualBackgroundKitPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MiVirtualBackgroundKitPlatform] when
  /// they register themselves.
  static set instance(MiVirtualBackgroundKitPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
