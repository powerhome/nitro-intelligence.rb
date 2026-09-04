module NitroIntelligence
  # One assistant resolved by name: the client for its deployment, plus the id every run has to
  # carry.
  #
  # Credentials are supplied by the host. Where they come from is the host's business -- an
  # environment variable its deployment mounts, a secrets store, a literal in configuration --
  # so nothing here encodes one deployment's wiring.
  class Assistant
    class ConfigurationError < StandardError; end

    DEFAULT_USER_ID = "default-user".freeze
    REQUIRED = %w[base_url api_key assistant_id].freeze

    attr_reader :name, :assistant_id, :base_url, :user_id

    # Extra keys are accepted and ignored: an entry carries fields the application has no use
    # for, such as the graph or the observability project it reports to.
    def initialize(name:, base_url: nil, api_key: nil, assistant_id: nil, user_id: nil, **_kwargs)
      @name = name.to_s
      @base_url = base_url.presence
      @api_key = api_key.presence
      @assistant_id = assistant_id.presence
      @user_id = user_id.presence || DEFAULT_USER_ID

      validate!
    end

    def client
      @client ||= Assistants.new(base_url: @base_url, api_key: @api_key, user_id: @user_id)
    end

    # The two calls that identify an assistant take it from here rather than from the caller.
    # Everything else is thread-scoped and delegates untouched.
    def await_run(thread_id:, messages:, **)
      client.await_run(thread_id:, assistant_id:, messages:, **)
    end

    def review_tool_calls(thread_id:, reviewer_id:, tool_calls:, **)
      client.review_tool_calls(thread_id:, assistant_id:, reviewer_id:, tool_calls:, **)
    end

    delegate :thread_state, :thread_messages, :tool_calls_pending_review, to: :client

  private

    # Reported together and named, since a host resolving these from somewhere else needs to
    # know which one it failed to supply.
    def validate!
      values = { "base_url" => @base_url, "api_key" => @api_key, "assistant_id" => @assistant_id }
      missing = REQUIRED.select { |field| values[field].blank? }
      return if missing.empty?

      raise ConfigurationError, "assistant #{@name.inspect} is missing #{missing.join(', ')}"
    end
  end
end
