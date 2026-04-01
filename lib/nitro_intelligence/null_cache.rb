module NitroIntelligence
  # Default no-operation cache implementation used
  # as a sensible default for initializing NitroIntelligence
  class NullCache
    def read(_key) = nil
    def write(_key, _value, **_options) = true
    def delete(_key) = true

    def fetch(key, **)
      value = read(key)
      return value unless value.nil?

      return unless block_given?

      computed = yield
      write(key, computed, **)
      computed
    end
  end
end
