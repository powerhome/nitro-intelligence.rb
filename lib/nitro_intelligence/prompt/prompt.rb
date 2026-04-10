module NitroIntelligence
  class Prompt
    attr_reader :name, :type, :prompt, :version, :config, :labels, :tags

    VARIABLE_REGEX = /\{\{([a-zA-Z0-9_]+)\}\}/

    def initialize(name:, type:, prompt:, version:, **extra_args)
      @name = name
      @type = type
      @prompt = prompt
      @version = version
      @config = extra_args[:config] || {}
      @labels = extra_args[:labels] || []
      @tags = extra_args[:tags] || []
    end

    # Returns prompt "content" from API with prompt variables replaced
    # Prompt "content" will either be a string or an array of hashes
    # based on prompt "type" ("text" or "chat")
    def compile(**replacements)
      return replace_variables(@prompt, **replacements) if @type == "text"

      @prompt.map do |message|
        message[:content] = replace_variables(message[:content], **replacements)
        message
      end
    end

    # Takes provided chat messages and inserts the compiled prompt
    # into the correct position based on prompt "type" ("text" or "chat")
    def interpolate(messages:, variables:)
      if @type == "text"
        messages.prepend({ role: "system", content: compile(**variables) })
      elsif @type == "chat"
        compile(**variables) + messages
      end
    end

    def variables
      messages = @type == "text" ? [@prompt] : @prompt.pluck(:content)

      messages.map do |message|
        message.scan(VARIABLE_REGEX).flatten.map(&:to_sym)
      end.flatten
    end

  private

    def replace_variables(input, **replacements)
      input.gsub(VARIABLE_REGEX) do |match|
        key = ::Regexp.last_match(1).to_sym
        replacements.fetch(key, match)
      end
    end
  end
end
