Pod::Spec.new do |s|
  s.name             = 'ffmpeg-kit-macos-min-gpl'
  s.version          = '6.0'
  s.summary          = 'FFmpegKit for macOS.'
  s.homepage         = 'https://github.com/arthenica/ffmpeg-kit'
  s.license          = { :type => 'LGPLv3' }
  s.author           = { 'Taner Sener' => 'tanersener@gmail.com' }
  s.platform         = :osx, '10.15'
  s.source           = { :http => 'https://github.com/arthenica/ffmpeg-kit/releases/download/v6.0/ffmpeg-kit-min-gpl-6.0-macos-xcframework.zip' }
  
  s.vendored_frameworks = '**/*.xcframework'
end
