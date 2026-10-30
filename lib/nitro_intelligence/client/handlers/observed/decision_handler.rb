require "nitro_intelligence/client/handlers/observed/base_handler"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        # Recorded as a generation, the closest observation type Langfuse has to a decision: it
        # carries the model, usage and cost. How a decision should be recorded is still open in
        # powerhome/cerebro#128.
        class DecisionHandler < BaseHandler
          def create(state:, questions:, parameters: {})
            @base_handler.validate_and_resolve!(parameters)

            trace_name = parameters[:trace_name] || project.slug

            # The questions alone say nothing about why the model answered as it did, so the
            # state they were asked about is recorded with them.
            @observer.observe(
              "decision",
              type: :generation,
              parameters:,
              trace_name:,
              input: { state:, questions: }
            ) do |generation|
              workflow(generation:, state:, questions:, parameters:)
            end
          end

        private

          def workflow(generation:, state:, questions:, parameters:)
            decision = @base_handler.perform_request(
              state:, questions:, parameters:, correlation_trace_id: generation.trace_id,
              mask_content: project.mask_content?
            )

            trace_attributes = {
              model: decision.model,
              output: decision.raw_answers,
              usage_details: usage_details(decision.usage),
              cost_details: @base_handler.cost_details(decision),
            }

            [decision, trace_attributes]
          end

          def usage_details(usage)
            input_tokens = usage[:input_tokens]
            output_tokens = usage[:output_tokens]
            return nil if input_tokens.nil? && output_tokens.nil?

            {
              prompt_tokens: input_tokens,
              completion_tokens: output_tokens,
              total_tokens: (input_tokens + output_tokens if input_tokens && output_tokens),
            }.compact
          end
        end
      end
    end
  end
end
