Pod::Spec.new do |s|
  s.name             = 'ffmpeg-kit-ios-min-gpl'
  s.version          = '6.0.2'
  s.summary          = 'FFmpegKit iOS Min GPL Package (Mirror using Full GPL)'
  s.description      = 'Using luthviar/ffmpeg-kit-ios-full mirror as min-gpl binaries are missing.'
  s.homepage         = 'https://github.com/arthenica/ffmpeg-kit'
  s.license          = { :type => 'LGPLv3' }
  s.author           = { 'Arthenica' => 'info@arthenica.com' }
  s.platform         = :ios, '12.1'
  s.source           = { :http => 'https://github.com/luthviar/ffmpeg-kit-ios-full/releases/download/6.0/ffmpeg-kit-ios-full.zip' }
  s.vendored_frameworks = 'ffmpeg-kit-ios-full/*.xcframework'
  s.module_name      = 'ffmpegkit'
end
