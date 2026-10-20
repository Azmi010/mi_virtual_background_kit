
import 'mi_virtual_background_kit_platform_interface.dart';

class MiVirtualBackgroundKit {
  Future<String?> getPlatformVersion() {
    return MiVirtualBackgroundKitPlatform.instance.getPlatformVersion();
  }
}
