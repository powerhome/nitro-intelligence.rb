require "nitro_intelligence/assistants"

module NitroIntelligence
  # One assistant resolved by name: the client for its deployment, plus the id every run has to
  # carry.
  #
  # Credentials are supplied by the host. Where they come from is the host's business -- an
  # environment variable its deployment mounts, a secrets store, a literal in configuration --
  # so nothing here encodes one deployment's wiring.
  #
  # @example
  #   assistant = NitroIntelligence.assistants["candidate-concierge"]
  #   result = assistant.run(thread_id:, messages:)
  class Assistant
    # Raised when an assistant's entry lacks its `api_key` or `assistant_id`, naming each one
    # missing.
    class ConfigurationError < StandardError; end

    # @api private
    DEFAULT_USER_ID = Assistants::DEFAULT_USER_ID

    # @api private
    # `base_url` is not among them: the client defaults it, so it cannot be missing.
    REQUIRED = %w[api_key assistant_id].freeze

    # The key an assistant is filed and looked up under. Not its name: an entry usually carries
    # a `name` of its own, a human-readable label for the assistant's record, and the two are
    # different things.
    #
    # @return [String]
    attr_reader :key

    # @return [String] the assistant's id in Assistants
    attr_reader :assistant_id
    # @return [String] the Assistants deployment that serves it
    attr_reader :base_url
    # @return [String] the user its threads are created for
    attr_reader :user_id

    # The key is positional so that splatting an entry cannot overwrite it, whatever the entry
    # happens to carry.
    #
    # Extra keys are accepted and ignored for the same reason: an entry carries fields the
    # application has no use for, such as the graph or the observability project it reports to.
    #
    # @api private
    def initialize(key, base_url: nil, api_key: nil, assistant_id: nil, user_id: nil, **_kwargs)
      @key = key.to_s
      @base_url = base_url.presence || Assistants::DEFAULT_BASE_URL
      @api_key = api_key.presence
      @assistant_id = assistant_id.presence
      @user_id = user_id.presence || DEFAULT_USER_ID

      validate!
    end

    # The client the assistant's calls go through, for anything this class does not expose.
    #
    # @return [Assistants]
    def client
      @client ||= Assistants.new(base_url: @base_url, api_key: @api_key, user_id: @user_id)
    end

    # The calls that identify an assistant take it from here rather than from the caller.
    # Everything else is thread-scoped and delegates untouched.
    #
    # {Assistants#run} for this assistant.
    #
    # @param thread_id [String]
    # @param messages [Array<Hash>]
    # @param kwargs [Hash] the rest of {Assistants#run}'s arguments, except `assistant_id`
    # @return [RunResult]
    # @raise [ArgumentError] when given an `assistant_id`
    # @raise (see Assistants#run)
    def run(thread_id:, messages:, **kwargs)
      reject_assistant_id!(kwargs)
      client.run(thread_id:, assistant_id:, messages:, **kwargs)
    end

    # {Assistants#await_run} for this assistant.
    #
    # @deprecated Use {#run}`(...).reply`. Removed in 5.0.
    # @param (see #run)
    # @return [String, nil]
    # @raise (see #run)
    def await_run(thread_id:, messages:, **kwargs)
      reject_assistant_id!(kwargs)
      client.await_run(thread_id:, assistant_id:, messages:, **kwargs)
    end

    # {Assistants#review} for this assistant.
    #
    # @param thread_id [String]
    # @param kwargs [Hash] the rest of {Assistants#review}'s arguments, except `assistant_id`
    # @return [RunResult]
    # @raise [ArgumentError] when given an `assistant_id`
    # @raise (see Assistants#review)
    def review(thread_id:, **kwargs)
      reject_assistant_id!(kwargs)
      client.review(thread_id:, assistant_id:, **kwargs)
    end

    # {Assistants#review_tool_calls} for this assistant.
    #
    # @deprecated Use {#review}`(tool_calls:, reviewer_id:, interrupt_id:)`. Removed in 5.0.
    # @param thread_id [String]
    # @param tool_calls [Hash, Array<Hash>]
    # @param kwargs [Hash] the rest of {Assistants#review_tool_calls}'s arguments, except
    #   `assistant_id`
    # @return [nil]
    # @raise [ArgumentError] when given an `assistant_id`
    # @raise (see Assistants#review_tool_calls)
    def review_tool_calls(thread_id:, tool_calls:, **kwargs)
      reject_assistant_id!(kwargs)
      client.review_tool_calls(thread_id:, assistant_id:, tool_calls:, **kwargs)
    end

    # @!method thread_state(thread_id:)
    #   {Assistants#thread_state}.
    #   @return (see Assistants#thread_state)
    # @!method thread_messages(thread_id:)
    #   {Assistants#thread_messages}.
    #   @return (see Assistants#thread_messages)
    # @!method tool_calls_pending_review(thread_id:)
    #   {Assistants#tool_calls_pending_review}.
    #   @deprecated (see Assistants#tool_calls_pending_review)
    #   @return (see Assistants#tool_calls_pending_review)
    # @!method tool_calls_under_review(thread_id:)
    #   {Assistants#tool_calls_under_review}.
    #   @deprecated (see Assistants#tool_calls_under_review)
    #   @return (see Assistants#tool_calls_under_review)
    # @!method under_review(thread_id:)
    #   {Assistants#under_review}.
    #   @return (see Assistants#under_review)
    delegate :thread_state, :thread_messages, :tool_calls_pending_review, :tool_calls_under_review,
             :under_review, to: :client

  private

    # An assistant supplies its own id, so a caller has no business passing one. It would land
    # in the trailing splat, which Ruby applies last, and quietly replace the configured id --
    # routing the call to a different assistant with nothing to show for it. Refuse instead.
    def reject_assistant_id!(kwargs)
      return unless kwargs.key?(:assistant_id)

      raise ArgumentError,
            "assistant #{@key.inspect} supplies its own assistant_id; remove it from the call"
    end

    # Reported together and named, since a host resolving these from somewhere else needs to
    # know which one it failed to supply.
    def validate!
      values = { "api_key" => @api_key, "assistant_id" => @assistant_id }
      missing = REQUIRED.select { |field| values[field].blank? }
      return if missing.empty?

      raise ConfigurationError, "assistant #{@key.inspect} is missing #{missing.join(', ')}"
    end
  end
end
