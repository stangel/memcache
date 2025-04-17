class Memcache
  class LocalServer < Base
    def initialize
      @data   = {}
      @expiry = {}
    end

    def name
      "local:#{hash}"
    end

    def stats
      { # curr_items may include items that have expired.
        'curr_items'   => @data.size,
        'expiry_count' => @expiry.size,
      }
    end

    def flush_all(delay = 0)
      raise 'flush_all not supported with delay' if delay != 0
      @data.clear
      @expiry.clear
    end

    def get(keys, cas = false)
      if keys.kind_of?(Array)
        hash = {}
        keys.each do |key|
          key    = key.to_s
          result = get(key)
          hash[key] = result if result
        end
        hash
      else
        key = cache_key(keys)
        if @expiry[key] and Time.now > @expiry[key]
          @data[key]   = nil
          @expiry[key] = nil
        end
        result = @data[key]
        result.clone if result
      end
    end

    def set(key, value, expiry = nil, flags = 0)
      key = cache_key(key)
      @data[key] = {:value => value.to_s, :flags => flags}
      expiry = Time.at(expiry) if expiry && expiry > Memcache::Base::EXPIRY_30DAYS
      expiry ||= @expiry[key]
      if expiry.kind_of?(Time)
        @expiry[key] = expiry
      else
        expiry = expiry.to_i
        @expiry[key] = expiry == 0 ? nil : Time.now + expiry
      end
      value
    end

    def delete(key)
      @data.delete(cache_key(key)) && true
    end
  end
end
