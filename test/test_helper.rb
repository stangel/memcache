begin
  require 'rubygems'
  require 'bundler'
rescue LoadError
  raise "Could not load the bundler gem. Install it with `gem install bundler`."
end

begin
  # Set up load paths for all bundled gems
  ENV["BUNDLE_GEMFILE"] = File.expand_path("../../Gemfile", __FILE__)
  Bundler.setup
rescue Bundler::GemNotFound
  raise RuntimeError, "Bundler couldn't find some gems.\nDid you run `bundle install`?"
end


require 'pp'
require 'test/unit'
require 'turn/autorun/testunit'

$:.unshift(File.expand_path('../../lib', __FILE__))
require 'memcache'

class Test::Unit::TestCase

  @@server_pids ||= {}

  def init_memcache(*ports)
    ports.each do |port|
      @@server_pids[port] ||= start_memcache(port)
    end

    @memcache = yield
    @memcache.flush_all

    at_exit { stop_memcaches }
  end

  def m
    @memcache
  end

  def start_memcache(port)
    system("memcached -p #{port} -U 0 -d -P /tmp/memcached_#{port}.pid")
    sleep 1
    File.read("/tmp/memcached_#{port}.pid")
  end

  def stop_memcaches
    @@server_pids.keys.each do |port|
      stop_memcache(port)
    end
    @@server_pids.clear
  end

  def stop_memcache(port)
    pid = File.read("/tmp/memcached_#{port}.pid")
    system("kill #{pid}")
  end

  def self.with_prefixes(*prefixes)
    # Define new test_* methods that calls super for every prefix. This only works for
    # methods that are mixed in, and should be called before you define custom test methods.
    opts = prefixes.last.is_a?(Hash) ? prefixes.last : {}
    instance_methods.each do |method_name|
      next unless method_name =~ /^test_/
      next if opts[:except] and opts[:except].include?(method_name)
      next if opts[:only] and not opts[:only].include?(method_name)

      define_method(method_name) do |*args|
        prefixes.each do |prefix|
          assert_equal prefix, m.prefix = prefix
          assert_equal prefix, m.prefix
          super()
          assert_equal nil, m.prefix = nil
          assert_equal nil, m.prefix
        end
      end
    end
  end
end

# simulate ActiveSupport::Duration class
module ActiveSupport
  class Duration
    def initialize(seconds)
      @seconds = seconds
    end

    def from_now
      Time.now + @seconds
    end
  end
end

