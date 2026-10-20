import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit_platform_interface.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockMiVirtualBackgroundKitPlatform
    with MockPlatformInterfaceMixin
    implements MiVirtualBackgroundKitPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final MiVirtualBackgroundKitPlatform initialPlatform = MiVirtualBackgroundKitPlatform.instance;

  test('$MethodChannelMiVirtualBackgroundKit is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelMiVirtualBackgroundKit>());
  });

  test('getPlatformVersion', () async {
    MiVirtualBackgroundKit miVirtualBackgroundKitPlugin = MiVirtualBackgroundKit();
    MockMiVirtualBackgroundKitPlatform fakePlatform = MockMiVirtualBackgroundKitPlatform();
    MiVirtualBackgroundKitPlatform.instance = fakePlatform;

    expect(await miVirtualBackgroundKitPlugin.getPlatformVersion(), '42');
  });
}
