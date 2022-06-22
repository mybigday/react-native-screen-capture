require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-screen-capture"
  s.version      = package["version"]
  s.summary      = "React Native Screen Capture"
  s.author       = { "Bricks Dev" => "dev@bricks.tools" }

  s.homepage     = "https://bricks.tools/"

  s.license      = "MIT"
  s.ios.deployment_target = "7.0"
  s.tvos.deployment_target = "9.0"

  s.source       = { :git => "https://github.com/mybigday/react-native-screen-capture.git", :tag => "#{s.version}" }

  s.source_files  = "ios/**/*.{h,m}"
  s.requires_arc = true

  s.dependency "React"
end