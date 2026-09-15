module NitroIntelligence
  module Observability
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

      # Takes the caller's prompt text and joins the compiled prompt in front of it, the
      # completion API's counterpart to #interpolate. A completion carries a single string
      # rather than a message list, so the prompt occupies no role: it is simply what the
      # model reads first.
      #
      # Text prompts only. A chat prompt's messages become a single string only once a
      # model's chat template has been applied, and that happens at the serving end of a
      # chat completion and nowhere else.
      def interpolate_text(text:, variables:)
        return nil unless @type == "text"

        [compile(**variables), text].select(&:present?).join("\n\n")
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
end
