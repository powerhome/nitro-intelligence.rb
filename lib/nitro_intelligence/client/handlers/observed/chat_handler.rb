require "nitro_intelligence/observability/prompt_resolver"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class ChatHandler
          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(message: "", parameters: {})
            @base_handler.validate_and_resolve!(parameters, message)

            prompt = handle_prompt(parameters:)
            trace_name = parameters[:trace_name] || prompt&.name || @observer.project_client.project.slug

            @observer.observe(
              "chat-completion",
              type: :generation,
              parameters:,
              trace_name:,
              prompt:,
              input: parameters[:messages]
            ) do |generation|
              workflow(generation:, parameters:)
            end
          end

        private

          def handle_prompt(parameters:)
            prompt = NitroIntelligence::Observability::PromptResolver.for(
              store: @observer.project_client.project.prompt_store,
              parameters:
            )
            return nil if prompt.blank?

            parameters[:messages] = prompt.interpolate(
              messages: parameters[:messages],
              variables: parameters[:prompt_variables] || {}
            )

            parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]

            prompt
          end

          def workflow(generation:, parameters:)
            chat_completion = @base_handler.perform_request(parameters:, correlation_trace_id: generation.trace_id)
            input = parameters[:messages]
            output = chat_completion.choices.first.message.to_h

            trace_attributes = {
              model: chat_completion.model,
              input:,
              output:,
              usage_details: {
                prompt_tokens: chat_completion.usage.prompt_tokens,
                completion_tokens: chat_completion.usage.completion_tokens,
                total_tokens: chat_completion.usage.total_tokens,
              },
            }

            [chat_completion, trace_attributes]
          end
        end
      end
    end
  end
end
