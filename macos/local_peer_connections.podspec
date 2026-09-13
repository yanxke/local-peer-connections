Pod::Spec.new do |s|
  s.name             = 'local_peer_connections'
  s.version          = '0.1.0'
  s.summary          = 'Offline, coordinator-routed proximity networking for Flutter.'
  s.description      = <<-DESC
Offline, coordinator-routed proximity networking for Flutter.
                       DESC
  s.homepage         = 'https://example.invalid/local_peer_connections'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'local_peer_connections' => 'dev@example.invalid' }
  s.source           = { :path => '.' }
  # CoreBluetooth is shared with the iOS backend. The macOS Classes entry is
  # a repository link to the implementation so the same backend behavior is
  # exercised on macOS and iOS; keeping one source avoids platform drift in
  # the GATT framing bridge.
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.swift_version = '5.0'
end
