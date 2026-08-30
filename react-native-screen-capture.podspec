require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-screen-capture"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.description  = package["description"]
  s.homepage     = "https://github.com/mybigday/react-native-screen-capture"
  s.license      = "MIT"
  s.author       = { "BRICKS INC." => "dev@bricks.tools" }

  s.platforms    = { :ios => "15.1", :tvos => "15.1" }

  s.source       = {
    :git => "https://github.com/mybigday/react-native-screen-capture.git",
    :tag => "v#{s.version}"
  }

  s.source_files  = "ios/ScreenCapture/**/*.{h,m,mm}"
  s.requires_arc  = true

  s.frameworks = "AVFoundation", "AVKit", "CoreImage", "CoreMedia", "CoreVideo", "Metal", "UIKit"

  # Pulls in React-Core, and wires up the new architecture when the app has it enabled.
  install_modules_dependencies(s)
end
