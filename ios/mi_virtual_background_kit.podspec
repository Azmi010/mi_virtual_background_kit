#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint mi_virtual_background_kit.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'mi_virtual_background_kit'
  s.version          = '0.1.1'
  s.summary          = 'Real-time virtual background effects for flutter_webrtc camera tracks.'
  s.description      = <<-DESC
Applies blur, image, and solid color background effects to local camera tracks
in flutter_webrtc based video call apps. Processing is fully on-device.
                       DESC
  s.homepage         = 'https://github.com/Azmi010/mi_virtual_background_kit'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Ulul Azmi' => 'ulul10039@gmail.com' }
  s.source           = { :git => 'https://github.com/Azmi010/mi_virtual_background_kit.git', :tag => s.version.to_s }
  s.source_files     = 'mi_virtual_background_kit/Sources/mi_virtual_background_kit/**/*.{h,m,swift}'
  s.resource_bundles = {
    'mi_virtual_background_kit' => [
      'mi_virtual_background_kit/Sources/mi_virtual_background_kit/Resources/**/*'
    ]
  }
  s.dependency 'Flutter'
  s.dependency 'flutter_webrtc', '~> 1.6.2'
  s.dependency 'MediaPipeTasksVision'
  s.platform         = :ios, '15.0'
  s.static_framework = true

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
end
