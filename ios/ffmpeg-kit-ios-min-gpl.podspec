Pod::Spec.new do |s|
  s.name             = 'ffmpeg-kit-ios-min-gpl'
  s.version          = '6.0'
  s.summary          = 'FFmpegKit iOS Min GPL Package (SourceForge Mirror)'
  s.homepage         = 'https://github.com/arthenica/ffmpeg-kit'
  s.license          = { :type => 'LGPLv3' }
  s.author           = { 'Arthenica' => 'info@arthenica.com' }
  s.platform         = :ios, '12.1'
  s.source           = { :http => 'https://downloads.sourceforge.net/project/ffmpegkit.mirror/v6.0/ffmpeg-kit-min-gpl-6.0-ios-xcframework.zip' }
  s.vendored_frameworks = 'ffmpeg-kit-min-gpl-6.0-ios-xcframework/*.xcframework'
end