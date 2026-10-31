require 'minitest/autorun'
require 'open3'
require 'rbconfig'

class ProxyBootTest < Minitest::Test
  # Load order is process-global: requiring net/http before socksify caches
  # native open_timeout support, which doesn't cover the SOCKS handshake.
  def test_boot_keeps_silent_socks_handshake_inside_open_timeout
    script = <<~'RUBY'
      require_relative 'config/boot'
      require 'socksify' # Also loaded by AppConfigurator#setup_proxy on prod.
      require 'net/http'
      require 'timeout'

      class ProbeDeadlineExceeded < StandardError; end

      server = TCPServer.new('127.0.0.1', 0)
      TCPSocket.socks_server = '127.0.0.1'
      TCPSocket.socks_port = server.addr[1]
      TCPSocket.socks_username = nil
      TCPSocket.socks_password = nil

      worker = Thread.new do
        begin
          peer = server.accept
          peer.read(3) # Accept the SOCKS greeting but never answer it.
          Queue.new.pop
        ensure
          peer&.close
        end
      end

      http = Net::HTTP.new('timeout-probe.invalid', 443, nil)
      http.use_ssl = true
      http.open_timeout = 0.1

      begin
        Timeout.timeout(3, ProbeDeadlineExceeded) { http.start {} }
        abort 'Expected the silent SOCKS handshake to time out'
      rescue Net::OpenTimeout
        puts 'SOCKS handshake raised Net::OpenTimeout'
      rescue ProbeDeadlineExceeded
        abort 'SOCKS handshake escaped Net::HTTP open_timeout'
      ensure
        worker.kill
        worker.join
        server.close
      end
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-e', script,
                                          chdir: File.expand_path('..', __dir__))

    assert status.success?, "Proxy timeout probe failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, 'SOCKS handshake raised Net::OpenTimeout'
  end
end
