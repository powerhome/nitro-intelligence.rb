module NitroIntelligence
  module Observability
    # A prompt managed in Cerebro, as {Project#prompt} and {Client::Base#prompt} return it. A request
    # that names a prompt with `prompt_name` uses one of these, but an application can also read one
    # itself, for its text or its `config`, without making a model call.
    class Prompt
      # @return [String] the prompt's name in Cerebro
      attr_reader :name
      # @return [String] `"text"` for a single string, or `"chat"` for a list of role-tagged messages
      attr_reader :type
      # @return [String, Array<Hash>] the prompt's content as Cerebro stores it, variables
      #   uncompiled: a string for a text prompt, or messages with `:role` and `:content` for a chat
      #   prompt. {#compile} fills in the variables.
      attr_reader :prompt
      # @return [Integer] the version Cerebro returned, which a later lookup can ask for to get the
      #   same prompt again
      attr_reader :version
      # @return [Hash{Symbol => Object}] the prompt's config, keys symbolized at every level, and
      #   empty when it has none
      attr_reader :config
      # @return [Array<String>] the labels this version carries, such as `"production"`
      attr_reader :labels
      # @return [Array<String>]
      attr_reader :tags

      # @api private
      VARIABLE_REGEX = /\{\{([a-zA-Z0-9_]+)\}\}/

      # @api private
      def initialize(name:, type:, prompt:, version:, **extra_args)
        @name = name
        @type = type
        @prompt = prompt
        @version = version
        @config = extra_args[:config] || {}
        @labels = extra_args[:labels] || []
        @tags = extra_args[:tags] || []
      end

      # The prompt's content with its `{{variables}}` filled in. A variable with no replacement is
      # left as it is.
      #
      # @param replacements [Hash{Symbol => #to_s}] each variable's value, by name
      # @return [String, Array<Hash>] a string for a text prompt, or new messages for a chat prompt,
      #   leaving this prompt's own uncompiled
      # @example
      #   client.prompt("Page Finder Search").compile(product: "Nitro")
      def compile(**replacements)
        return replace_variables(@prompt, **replacements) if @type == "text"

        # New messages, so the prompt keeps its variables for the next request that compiles it.
        @prompt.map do |message|
          message.merge(content: replace_variables(message[:content], **replacements))
        end
      end

      # @api private
      #
      # Takes provided chat messages and inserts the compiled prompt
      # into the correct position based on prompt "type" ("text" or "chat")
      def interpolate(messages:, variables:)
        if @type == "text"
          [{ role: "system", content: compile(**variables) }] + messages
        elsif @type == "chat"
          compile(**variables) + messages
        end
      end

      # The names of the `{{variables}}` the prompt's content uses, in order of appearance.
      #
      # @return [Array<Symbol>]
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
