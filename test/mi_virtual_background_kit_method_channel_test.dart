import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelMiVirtualBackgroundKit platform = MethodChannelMiVirtualBackgroundKit();
  const MethodChannel channel = MethodChannel('mi_virtual_background_kit');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return '42';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
