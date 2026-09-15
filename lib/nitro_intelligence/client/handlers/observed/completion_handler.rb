require "nitro_intelligence/observability/prompt_resolver"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class CompletionHandler
          class ObservedCompletionPromptError < StandardError; end

          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(message: "", parameters: {})
            @base_handler.validate_and_resolve!(parameters, message)

            prompt = handle_prompt(parameters:)
            trace_name = parameters[:trace_name] || prompt&.name || @observer.project_client.project.slug

            @observer.observe(
              "completion",
              type: :generation,
              parameters:,
              trace_name:,
              prompt:,
              input: parameters[:prompt]
            ) do |generation|
              workflow(generation:, parameters:)
            end
          end

        private

          # A chat prompt is rejected rather than flattened. Its messages carry roles that
          # only a chat template knows how to render, and this endpoint applies none, so
          # any joining this handler invented would be a guess at the model's own format.
          def handle_prompt(parameters:)
            prompt = NitroIntelligence::Observability::PromptResolver.for(
              store: @observer.project_client.project.prompt_store,
              parameters:
            )
            return nil if prompt.blank?

            if prompt.type != "text"
              raise ObservedCompletionPromptError, "Prompt type for a completion must be text: #{prompt.name}"
            end

            parameters[:prompt] = prompt.interpolate_text(
              text: parameters[:prompt],
              variables: parameters[:prompt_variables] || {}
            )

            parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]

            prompt
          end

          def workflow(generation:, parameters:)
            completion = @base_handler.perform_request(parameters:, correlation_trace_id: generation.trace_id)

            trace_attributes = {
              model: completion.model,
              output: completion.choices.first.text,
              usage_details: {
                prompt_tokens: completion.usage.prompt_tokens,
                completion_tokens: completion.usage.completion_tokens,
                total_tokens: completion.usage.total_tokens,
              },
              cost_details: @base_handler.cost_details(completion),
            }

            [completion, trace_attributes]
          end
        end
      end
    end
  end
end
