class Hash

unless defined?(symbolize_keys)
  def symbolize_keys
    inject({}) do |hash, (key, value)|
      hash[(key.to_sym rescue key) || key] = value
      hash
    end
  end
end

end
