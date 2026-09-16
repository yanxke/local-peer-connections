Pod::Spec.new do |s|
  s.name = 'local_peer_connections'
  s.version = '0.1.0'
  s.summary = 'Local Peer Connections Flutter plugin.'
  s.description = 'Platform registration for Local Peer Connections.'
  s.homepage = 'https://example.invalid/local_peer_connections'
  s.license = { :file => '../LICENSE' }
  s.author = { 'OpenAI' => 'noreply@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.swift_version = '5.0'
end
