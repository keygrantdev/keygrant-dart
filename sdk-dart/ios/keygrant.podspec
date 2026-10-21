#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint keygrant.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'keygrant'
  s.version          = '0.1.1'
  s.summary          = 'KeyGrant licensing for Flutter apps.'
  s.description      = <<-DESC
The KeyGrant plugin's native side: the device id KeyGrant licenses are held to.
                       DESC
  s.homepage         = 'https://keygrant.dev'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'KeyGrant' => 'dev@keygrant.dev' }
  s.source           = { :path => '.' }
  s.source_files = 'keygrant/Sources/keygrant/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'keygrant_privacy' => ['keygrant/Sources/keygrant/PrivacyInfo.xcprivacy']}
end
