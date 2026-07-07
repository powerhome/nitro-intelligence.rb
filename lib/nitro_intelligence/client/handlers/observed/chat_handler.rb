module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class ChatHandler
          # A prompt the caller has already resolved and interpolated itself, supplied purely so the trace
          # can be linked to it (populates Langfuse promptName/promptVersion). Unlike `prompt_name`, it does
          # not trigger a fetch, interpolation, or config merge -- only `.name`/`.version` are read.
          LinkedPrompt = Data.define(:name, :version)

          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(message: "", parameters: {})
            @base_handler.validate_and_resolve!(parameters, message)

            prompt = handle_prompt(parameters:) || link_only_prompt(parameters)
            trace_name = parameters[:trace_name] || prompt&.name || @observer.project_client.project.slug

            @observer.observe(
              "chat-completion",
              type: :generation,
              parameters:,
              trace_name:,
              prompt:
            ) do |_generation|
              workflow(parameters:)
            end
          end

        private

          def handle_prompt(parameters:)
            return nil if parameters[:prompt_name].blank?

            prompt = @observer.project_client.project.prompt_store.get_prompt(
              prompt_name: parameters[:prompt_name],
              prompt_label: parameters[:prompt_label],
              prompt_version: parameters[:prompt_version]
            )
            prompt_variables = parameters[:prompt_variables] || {}

            if prompt.present?
              parameters[:messages] = prompt.interpolate(
                messages: parameters[:messages],
                variables: prompt_variables
              )

              parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]
            end

            prompt
          end

          # Links a pre-resolved prompt (name + version) without any fetch/interpolation. Returns nil when no
          # linked_prompt was supplied, so the caller falls through to the unlinked case.
          def link_only_prompt(parameters)
            reference = parameters[:linked_prompt]
            return if reference.blank?

            LinkedPrompt.new(**reference)
          end

          def workflow(parameters:)
            chat_completion = @base_handler.perform_request(parameters:)
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
