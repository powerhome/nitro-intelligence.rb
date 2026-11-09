require "nitro_intelligence/observation"
require "nitro_intelligence/trace"

module NitroIntelligence
  # Records application code in Cerebro as a trace, with the gem's requests made inside it nested
  # under it, for a feature whose work is more than one model call.
  #
  # @example
  #   tracer = NitroIntelligence::Tracer.new(observability_project_slug: "page-finder")
  #   client = NitroIntelligence::Client.new(observability_project_slug: "page-finder")
  #
  #   tracer.trace("Page Finder search", input: { question: }, user_id: current_user.id.to_s) do |trace|
  #     query = client.chat(message: question) # recorded inside the trace
  #     hits = trace.observe("Elasticsearch", as_type: :retriever, input: { k: 50 }) do |step|
  #       search(query).tap { |hits| step.output = hits.map(&:page_id) }
  #     end
  #     trace.output = hits.map(&:page_id)
  #   end
  class Tracer
    # @param observability_project_slug [String] the Cerebro project to record in. The gem's
    #   requests nest under the trace only when their client records in the same project.
    # @raise [Observability::Project::NotFoundError] when `observability_projects` does not configure
    #   the project
    def initialize(observability_project_slug:)
      @project_client = NitroIntelligence.project_client_registry.fetch(observability_project_slug)
    end

    # Records the block as a trace of its own, even inside another trace, with its environment and
    # release set as the gem's requests set them. The gem's requests made inside the block, through a
    # client for the same project and without a `trace_seed`, are recorded as observations in this
    # trace instead of traces of their own: the trace's name, input, output, user, session and tags are
    # the ones given here, and the request's `trace_name`, `user_id`, `session_id` and `tags` are not
    # recorded. An exception the block raises is recorded on the trace at level `ERROR`, and re-raised.
    #
    # @param name [String] the trace's name
    # @param as_type [Symbol] the type of the trace's root observation, one of {Observation::TYPES}
    # @param input [Object, nil] the trace's input. Set it later with {Observation#input=}.
    # @param metadata [Hash] recorded on the trace and every observation in it, with each value
    #   converted to a String. It is not masked.
    # @param user_id [String, nil] the application's user, defaulting to `observability_user_id`
    # @param session_id [String, nil] groups related traces
    # @param tags [Array<String>, nil] labels the trace for filtering
    # @param trace_seed [String, nil] gives the trace the ID {Trace.create_id} gives for the seed,
    #   rather than a random one
    # @yieldparam trace [Observation] the trace's root observation
    # @return [Object] the block's value
    # @raise [ArgumentError] when `as_type` is not one of {Observation::TYPES}, or no block is given
    def trace(name, as_type: :span, input: nil, metadata: {}, user_id: nil, session_id: nil, tags: nil, # rubocop:disable Metrics/ParameterLists
              trace_seed: nil, &)
      raise ArgumentError, "a block is required" unless block_given?
      unless Observation::TYPES.include?(as_type)
        raise ArgumentError, "as_type must be one of #{Observation::TYPES.join(', ')}, not #{as_type.inspect}"
      end

      propagated = propagated_attributes(metadata:, user_id:, session_id:, tags:)
      LangfuseExtension.in_new_trace do
        Langfuse.propagate_attributes(**propagated) { start(name, as_type:, input:, trace_seed:).run(&) }
      end
    end

  private

    def start(name, as_type:, input:, trace_seed:)
      observability_client = @project_client.observability_client
      trace_id = trace_seed.present? ? Trace.create_id(seed: trace_seed) : Langfuse.create_trace_id

      langfuse_observation = observability_client.start_observation(
        name, { environment: NitroIntelligence.environment.to_s }, as_type:, trace_id:
      )
      langfuse_observation.update_trace(name:, release: NitroIntelligence.configuration.current_revision)

      Observation.new(
        langfuse_observation, observability_client:, project: @project_client.project, root: true
      ).tap { |observation| observation.input = input unless input.nil? }
    end

    def propagated_attributes(metadata:, user_id:, session_id:, tags:)
      attributes = {
        user_id: user_id || NitroIntelligence.configuration.observability_user_id,
        metadata: metadata.to_h.transform_values(&:to_s),
      }
      attributes[:session_id] = session_id if session_id.present?
      attributes[:tags] = tags if tags.present?
      attributes
    end
  end
end
