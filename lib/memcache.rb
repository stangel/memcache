require 'zlib'

$:.unshift(File.dirname(__FILE__))
require 'memcache/base'
require 'memcache/server'
require 'memcache/local_server'
begin
  require 'memcache/native_server'
rescue LoadError => e
  puts "memcache is not using native bindings."
  puts "For faster performance, compile extensions by hand or install as a local gem."
  # Sometimes ruby can't find a dependent .so file (eg libmemcached.so.11).
  # The error message will tell us which file ruby couldn't find.
  puts "Cause:\n\t#{e.message}\n"
end

require 'memcache/segmented'

class Memcache
  DEFAULT_EXPIRY  = 0
  LOCK_TIMEOUT    = 5
  WRITE_LOCK_WAIT = 1

  attr_reader :default_expiry, :namespace, :servers, :backup

  class Error < StandardError; end
  class ConnectionError < Error
    def initialize(e)
      if e.kind_of?(String)
        super
      else
        super("(#{e.class}) #{e.message}")
        set_backtrace(e.backtrace)
      end
    end
  end
  class ServerError        < Error ; end
  class ClientError        < Error ; end
  class UnmarshalException < Error ; end

  def initialize(opts)
    @default_expiry   = opts[:default_expiry] || DEFAULT_EXPIRY
    @backup           = opts[:backup] # for multi-level caches
    @hash_with_prefix = opts[:hash_with_prefix].nil? ? true : opts[:hash_with_prefix]

    if opts[:native]
      native_opts = opts.clone
      native_opts[:servers] = (opts[:servers] || [ opts[:server] ]).collect do |server|
        server.is_a?(Hash) ? "#{server[:host]}:#{server[:port]}:#{server[:weight]}" : server
      end
      native_opts[:hash] ||= :crc unless native_opts[:ketama] or native_opts[:ketama_wieghted]
      native_opts[:hash_with_prefix] = @hash_with_prefix

      server_class = opts[:segment_large_values] ? SegmentedNativeServer : NativeServer
      @servers = [server_class.new(native_opts)]
    else
      raise "only CRC hashing is supported unless :native => true" if opts[:hash] and opts[:hash] != :crc

      server_class = opts[:segment_large_values] ? SegmentedServer : Server
      @servers = (opts[:servers] || [ opts[:server] ]).collect do |server|
        case server
        when Hash
          server = server_class.new(opts.merge(server))
        when String
          host, port = server.split(':')
          server = server_class.new(opts.merge(:host => host, :port => port))
        when Class
          server = server.new
        when :local
          server = Memcache::LocalServer.new
        end
        server
      end
    end

    @server = @servers.first if @servers.size == 1 and @backup.nil?
    self.namespace = opts[:namespace] if opts[:namespace]
  end

  def clone
    self.class.new(
      :default_expiry => default_expiry,
      :namespace      => namespace,
      :servers        => servers.collect {|s| s.clone}
    )
  end

  def inspect
    "<Memcache: %d servers, ns: %p>" % [@servers.length, namespace]
  end

  def namespace=(namespace)
    @namespace = namespace
    prefix = namespace ? "#{namespace}:" : nil
    servers.each do |server|
      server.prefix = prefix
    end
    backup.namespace = @namespace if backup
    @namespace
  end

  def in_namespace(namespace)
    # Temporarily change the namespace for convenience.
    begin
      old_namespace  = self.namespace
      self.namespace = old_namespace ? "#{old_namespace}:#{namespace}" : namespace
      yield
    ensure
      self.namespace = old_namespace
    end
  end

  def get(keys, opts = {})
    raise 'opts must be hash' unless opts.instance_of?(Hash)
    if keys.instance_of?(Array)
      keys = keys.collect {|key| key.to_s}
      multi_get(keys, opts)
    else
      key = keys.to_s
      if opts[:expiry]
        result = server(key).gets(key)
        cas(key, result[:value], :raw => true, :cas => result[:cas], :expiry => opts[:expiry]) if result
      else
        result = server(key).get(key, opts[:cas])
      end

      if result
        unless opts[:raw]
          result[:value] = unmarshal(result[:value], key) rescue nil
        end

        opts[:meta] ? result : result[:value]
      elsif backup
        backup.get(key, opts)
      end
    end
  end

  def read(key, opts = nil)
    opts ||= {}
    get(key, opts.merge(:raw => true))
  end

  def read_multi(*keys)
    get(keys)
  end

  def set(key, value, opts = {})
    opts = compatible_opts(opts)
    key  = key.to_s
    backup.set(key, value, opts) if backup

    expiry = parse_expiry(opts) || default_expiry
    flags  = opts[:flags]       || 0
    data   = marshal(value, opts)
    server(key).set(key, data, expiry, flags)
    value
  end

  def write(key, value, opts = nil)
    opts ||= {}
    set(key, value, opts.merge(:raw => true))
  end

  def add(key, value, opts = {})
    opts = compatible_opts(opts)
    key  = key.to_s
    backup.add(key, value, opts) if backup

    expiry = parse_expiry(opts) || default_expiry
    flags  = opts[:flags]       || 0
    data   = marshal(value, opts)
    server(key).add(key, data, expiry, flags) && value
  end

  def replace(key, value, opts = {})
    opts = compatible_opts(opts)
    key  = key.to_s
    backup.replace(key, value, opts) if backup

    expiry = parse_expiry(opts) || default_expiry
    flags  = opts[:flags]       || 0
    data   = marshal(value, opts)
    server(key).replace(key, data, expiry, flags) && value
  end

  def cas(key, value, opts)
    raise 'opts must be hash' unless opts.instance_of?(Hash)
    key = key.to_s
    backup.cas(key, value, opts) if backup

    expiry = parse_expiry(opts) || default_expiry
    flags  = opts[:flags]       || 0
    data   = marshal(value, opts)
    server(key).cas(key, data, opts[:cas], expiry, flags) && value
  end

  def append(key, value)
    key = key.to_s
    backup.append(key, value) if backup
    server(key).append(key, value)
  end

  def prepend(key, value)
    key = key.to_s
    backup.prepend(key, value) if backup
    server(key).prepend(key, value)
  end

  def count(key)
    value = get(key, :raw => true)
    value.to_i if value
  end

  def incr(key, amount = 1)
    return decr(key, -amount) if amount < 0

    key = key.to_s
    backup.incr(key, amount) if backup
    server(key).incr(key, amount)
  end

  def decr(key, amount = 1)
    return incr(key, -amount) if amount < 0

    key = key.to_s
    backup.decr(key, amount) if backup
    server(key).decr(key, amount)
  end

  def update(key, opts = {})
    key    = key.to_s
    result = get(key, :cas => true, :meta => true)
    if result
      cas(key, yield(result[:value]), opts.merge!(:cas => result[:cas]))
    else
      add(key, yield(result[:value]), opts)
    end
  end

  def get_or_add(key, *args, &block)
    # Pseudo-atomic get and update.
    key = key.to_s
    if block
      opts = args[0] || {}
    else
      opts = args[1] || {}
      block = lambda { args[0] }
    end
    get(key, opts) || add(key, block.call(), opts) || get(key, opts)
  end

  def get_or_set(key, *args, &block)
    key = key.to_s
    if block_given?
      opts = args[0] || {}
    else
      opts = args[1] || {}
      block = lambda { args[0] }
    end
    get(key, opts) || set(key, block.call(), opts)
  end

  def add_or_get(key, value, opts = {})
    # Try to add, but if that fails, get the existing value.
    add(key, value, opts) || get(key, opts)
  end

  def get_some(keys, opts = {})
    keys    = keys.collect {|key| key.to_s}
    results = opts[:disable] ? {} : self.multi_get(keys, opts)
    if opts[:validation]
      results.delete_if do |key, result|
        value = opts[:meta] ? result[:value] : result
        not opts[:validation].call(key, value)
      end
    end

    keys_to_fetch = keys - results.keys
    if keys_to_fetch.any?
      yield(keys_to_fetch).each do |key, value|
        begin
          set(key, value, {}) unless opts[:disable] or opts[:disable_write]
        rescue Memcache::Error => e
          raise if opts[:strict_write]
          key = key.dup.force_encoding('BINARY' )
          msg = "Memcache error in get_some: #{e.class} #{e.to_s} on key '#{key}' while storing value: #{value}"
          $stderr.puts msg
        end
        results[key] = opts[:meta] ? {:value => value} : value
      end
    end
    results
  end

  def lock(key, opts = {})
    # Returns false if the lock already exists.
    expiry = parse_expiry(opts) || LOCK_TIMEOUT
    add(lock_key(key), Socket.gethostname, :expiry => expiry, :raw => true)
  end

  def unlock(key)
    delete(lock_key(key))
  end

  def with_lock(key, opts = {})
    until lock(key, opts) do
      return if opts[:ignore]
      sleep(WRITE_LOCK_WAIT) # just wait
    end

    begin
      yield
    ensure
      unlock(key) unless opts[:keep]
    end
  end

  def lock_key(key)
    "lock:#{key}"
  end

  def locked?(key)
    get(lock_key(key), :raw => true)
  end

  def delete(key, opts = nil)
    key = key.to_s
    backup.delete(key) if backup
    server(key).delete(key)
  end

  def flush_all(opts = {})
    delay    = opts[:delay].to_i
    interval = opts[:interval].to_i

    servers.each do |server|
      server.flush_all(delay)
      delay += interval
    end
  end

  def reset
    servers.each {|server| server.close if server.respond_to?(:close)}
  end

  def stats(field = nil)
    if field
      servers.collect do |server|
        server.stats[field]
      end
    else
      stats = {}
      servers.each do |server|
        stats[server.name] = server.stats
      end
      stats
    end
  end

  alias clear flush_all

  def [](key)
    get(key)
  end

  def []=(key, value)
    set(key, value)
  end

  def self.init(yaml_file = nil)
    yaml_file ||= File.join(Rails.root, 'config', 'memcached.yml')

    if File.exists?(yaml_file)
      yaml = YAML.load_file(yaml_file)
      defaults = (yaml.delete('defaults') || {}).symbolize_keys
      config   = (yaml[Rails.env] || {}).symbolize_keys

      if not config.empty? and not config[:disabled]
        if config[:servers]
          opts = defaults.merge(config.symbolize_keys)
          Object.const_set('CACHE', Memcache.new(opts))
        else
          config.each do |connection, opts|
            opts = defaults.merge(opts.symbolize_keys)
            if not opts.empty? and not opts[:disabled]
              Memcache.pool[connection] = Memcache.new(opts)
            end
          end
        end
      end
    end
  end

protected

  EXPIRY_SECONDS_LIMIT = 2592000  # silent failure beyond!
  def parse_expiry(opts)
    # This is here to prevent accidentally passing :expiry => 3.months and then never realizing
    # nothing gets cached.  See https://github.com/memcached/memcached/wiki/Programming#expiration
    exp = opts[:expiry]

    if Object.const_defined?('ActiveSupport::Duration')
      return exp.from_now.to_i if exp.is_a?(ActiveSupport::Duration)
    end

    case exp.class.to_s
    when 'NilClass'
      nil
    when 'Time'
      exp.to_i
    when 'Date', 'DateTime'
      exp.to_time.to_i
    when 'Fixnum'
      if exp > EXPIRY_SECONDS_LIMIT
        raise ArgumentError.new("Expiry seconds cannot be more than 30 days!  Pass a Date, Time or Duration instead.")
      else
        exp
      end
    else
      exp
    end
  end

  def compatible_opts(opts)
    # Support passing expiry instead of opts. This may be deprecated in the future.
    opts.instance_of?(Hash) ? opts : {:expiry => opts}
  end

  def multi_get(keys, opts = {})
    return {} if keys.empty?

    results = {}
    fetch_results = lambda do |server, keys|
      server.get(keys, opts[:cas]).each do |key, result|
        begin
          result[:value] = unmarshal(result[:value], key) unless opts[:raw]
          results[key] = opts[:meta] ? result : result[:value]
        rescue UnmarshalException
          # do not set results[key] --> missing_keys
        end
      end
    end

    if @server
      fetch_results.call(@server, keys)
    else
      keys_by_server = Hash.new { |h,k| h[k] = [] }

      # Store keys by servers.
      keys.each do |key|
        keys_by_server[server(key)] << key
      end

      # Fetch and combine the results.
      keys_by_server.each do |server, server_keys|
        fetch_results.call(server, server_keys)
      end
    end

    if backup
      missing_keys = keys - results.keys
      results.merge!(backup.get(missing_keys, opts)) if missing_keys.any?
    end
    results
  end

  def marshal(value, opts = {})
    opts[:raw] ? value : Marshal.dump(value)
  end

  def unmarshal(value, key)
    return value if value.nil?
    Marshal.load(value)
  rescue Exception => e
    key = key.dup.force_encoding('BINARY' )
    msg = "Memcache read error: #{e.class} #{e.to_s} on key '#{key}' while unmarshalling value: #{value}"
    $stderr.puts msg, caller
    delete(key)
    raise UnmarshalException.new(msg)
  end

  def server(key)
    return @server if @server

    key = "#{namespace}:#{key}" if @hash_with_prefix and namespace
    hash = (Zlib.crc32(key) >> 16) & 0x7fff
    servers[hash % servers.length]
  end

  class Pool
    attr_reader :fallback

    def initialize
      @cache_by_scope = {}
      @cache_by_scope[:default] = Memcache.new(:server => Memcache::LocalServer)
      @fallback = :default
    end

    def include?(scope)
      @cache_by_scope.include?(scope.to_sym)
    end

    def fallback=(scope)
      @fallback = scope.to_sym
    end

    def [](scope)
      @cache_by_scope[scope.to_sym] || @cache_by_scope[fallback]
    end

    def []=(scope, cache)
      @cache_by_scope[scope.to_sym] = cache
    end

    def reset
      @cache_by_scope.values.each {|c| c.reset}
    end
  end

  def self.pool
    @@cache_pool ||= Pool.new
  end
end
