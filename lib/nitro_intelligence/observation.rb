module NitroIntelligence
  # A step of application code recorded in Cerebro, as {Tracer#trace} and {#observe} yield it.
  #
  # A project that masks content records the input and output given here as `[masked]`, as it does
  # for the gem's own requests. Metadata is recorded as given, so keep content out of it.
  class Observation
    # The Langfuse observation types {#observe} accepts.
    TYPES = (Langfuse::OBSERVATION_TYPES.keys - [:event]).freeze

    # @api private
    MAX_STATUS_MESSAGE_LENGTH = 2000

    # @api private
    def initialize(langfuse_observation, observability_client:, project:, root: false)
      @observation = langfuse_observation
      @observability_client = observability_client
      @project = project
      @root = root
    end

    # @return [String] the observation's ID, for scoring it with {Reporter#score}
    def id
      @observation.id
    end

    # @return [String] the ID of the trace the observation is in, for scoring it with {Reporter#score}
    def trace_id
      @observation.trace_id
    end

    # Records what the step was given. On the observation {Tracer#trace} yields, this is the
    # trace's input too.
    #
    # @param value [Object] anything that serializes to JSON
    def input=(value)
      value = @project.mask(value)
      @observation.input = value
      @observation.update_trace(input: value) if @root
    end

    # Records what the step produced. On the observation {Tracer#trace} yields, this is the
    # trace's output too.
    #
    # @param value [Object] anything that serializes to JSON
    def output=(value)
      value = @project.mask(value)
      @observation.output = value
      @observation.update_trace(output: value) if @root
    end

    # Records metadata on the observation. It is not masked.
    #
    # @param value [Hash]
    def metadata=(value)
      @observation.metadata = value
    end

    # Records a step inside this one, around a block. The gem's requests made inside the block nest
    # under the step. An exception the block raises is recorded on the step at level `ERROR`, and
    # re-raised.
    #
    # @param name [String] what the step does
    # @param as_type [Symbol] one of {TYPES}, such as `:span`, `:retriever` or `:tool`
    # @param input [Object, nil] what the step is given
    # @param metadata [Hash, nil]
    # @yieldparam observation [Observation] the step, to record its output on
    # @return [Object] the block's value
    # @raise [ArgumentError] when `as_type` is not one of {TYPES}, or no block is given
    # @example
    #   hits = root_observation.observe("Elasticsearch", as_type: :retriever, input: { k: 50 }) do |step|
    #     search(question).tap { |hits| step.output = hits.map(&:page_id) }
    #   end
    def observe(name, as_type: :span, input: nil, metadata: nil, &)
      raise ArgumentError, "a block is required" unless block_given?
      unless TYPES.include?(as_type)
        raise ArgumentError, "as_type must be one of #{TYPES.join(', ')}, not #{as_type.inspect}"
      end

      child = @observability_client.start_observation(
        name,
        attributes(input:, metadata:),
        as_type:,
        parent_span_context: @observation.otel_span.context
      )
      Observation.new(child, observability_client: @observability_client, project: @project).run(&)
    end

    # Records something that happened at a point in time inside this step, such as a user's choice.
    #
    # @param name [String] what happened
    # @param input [Object, nil]
    # @param output [Object, nil]
    # @param metadata [Hash, nil]
    # @return [void]
    def event(name, input: nil, output: nil, metadata: nil)
      @observability_client.start_observation(
        name,
        attributes(input:, output:, metadata:),
        as_type: :event,
        parent_span_context: @observation.otel_span.context
      )
      nil
    end

    # @api private
    #
    # Runs the block with this observation active, records an exception it raises, and ends the
    # observation.
    def run
      @observability_client.within(@observation) { yield self }
    rescue => e
      @observation.update(level: "ERROR", status_message: failure_message(e))
      raise
    ensure
      @observation.end
    end

  private

    def attributes(input: nil, output: nil, metadata: nil)
      {
        input: @project.mask(input),
        output: @project.mask(output),
        metadata:,
        environment: NitroIntelligence.environment.to_s,
      }.compact
    end

    # The message of an exception can quote what the step was given, so a masked project records
    # which exception it was and nothing it said.
    def failure_message(error)
      return error.class.to_s if @project.mask_content?

      "#{error.class}: #{error.message}".truncate(MAX_STATUS_MESSAGE_LENGTH)
    end
  end
end
