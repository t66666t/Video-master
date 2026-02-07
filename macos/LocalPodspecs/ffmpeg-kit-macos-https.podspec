Pod::Spec.new do |s|
  s.name             = 'ffmpeg-kit-macos-https'
  s.version          = '6.0'
  s.summary          = 'FFmpegKit for macOS (HTTPS variant).'
  s.homepage         = 'https://github.com/arthenica/ffmpeg-kit'
  s.license          = { :type => 'LGPLv3' }
  s.author           = { 'Taner Sener' => 'tanersener@gmail.com' }
  s.platform         = :osx, '10.15'
  s.source           = { :http => 'https://sourceforge.net/projects/ffmpegkit.mirror/files/v6.0/ffmpeg-kit-https-6.0-macos-xcframework.zip/download' }
  s.vendored_frameworks = '**/*.xcframework'
end
