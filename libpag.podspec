Pod::Spec.new do |s|
  s.name = 'libpag'
  s.version = '4.5.70-metal.2'
  s.summary = 'Metal-backed libpag build for iOS.'
  s.homepage = 'https://github.com/Arthas-cn/libpag-Metal'
  s.license = { :type => 'Apache-2.0' }
  s.author = { 'Arthas-cn' => 'https://github.com/Arthas-cn' }
  s.source = { :git => 'https://github.com/Arthas-cn/libpag-Metal.git', :tag => s.version.to_s }
  s.platform = :ios, '15.0'
  s.requires_arc = false
  s.vendored_frameworks = 'libpag.xcframework'
end
