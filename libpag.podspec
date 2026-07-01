Pod::Spec.new do |s|
  s.name = 'libpag'
  s.version = '4.5.70-metal.1'
  s.summary = 'Metal-backed libpag build for iOS.'
  s.homepage = 'https://github.com/Tencent/libpag'
  s.license = { :type => 'Apache-2.0' }
  s.author = { 'Tencent' => 'opensource@tencent.com' }
  s.source = { :git => 'file:///Users/arthas/shibo/iOSProject/libpag-Metal' }
  s.platform = :ios, '15.0'
  s.requires_arc = false
  s.vendored_frameworks = 'libpag.xcframework'
end
