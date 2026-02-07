Pod::Spec.new do |s|
  s.name             = 'ffmpeg-kit-macos-https'
  s.version          = '6.0'
  s.summary          = 'FFmpegKit for macOS (HTTPS variant).'
  s.homepage         = 'https://github.com/arthenica/ffmpeg-kit'
  s.license          = { :type => 'LGPLv3' }
  s.author           = { 'Taner Sener' => 'tanersener@gmail.com' }
  s.platform         = :osx, '10.15'
  s.source           = { :http => 'https://codeload.github.com/arthenica/ffmpeg-kit/zip/refs/tags/flutter.v6.0.3' }
  s.vendored_frameworks = '**/*.xcframework'
end
