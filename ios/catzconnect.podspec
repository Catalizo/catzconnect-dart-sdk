#
# The catzconnect plugin's iOS side: App Attest (DCAppAttestService) for
# Catz Connect app keys, on the `catzconnect/attest` method channel.
# The same sources are built by Swift Package Manager (catzconnect/Package.swift).
#
Pod::Spec.new do |s|
  s.name             = 'catzconnect'
  s.version          = '2.0.0'
  s.summary          = 'Catz Connect SDK for Flutter: App Attest for app keys.'
  s.description      = <<-DESC
The native part of the Catz Connect Flutter SDK: Apple App Attest
(DeviceCheck) key generation, attestation and assertions for app keys.
                       DESC
  s.homepage         = 'https://catzconnect.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Catalizo' => 'info@catalizo.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'catzconnect/Sources/catzconnect/**/*.swift'
  s.resource_bundles = { 'catzconnect_privacy' => ['catzconnect/Sources/catzconnect/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.frameworks       = 'DeviceCheck'
  # iOS 13 so existing apps keep building; App Attest needs iOS 14 (checked at run time).
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
