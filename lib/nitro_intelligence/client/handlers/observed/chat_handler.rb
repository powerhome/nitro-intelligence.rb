require "nitro_intelligence/observability/prompt_resolver"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class ChatHandler
          class ObservedChatPromptError < StandardError; end

          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(message: "", parameters: {})
            @base_handler.validate_and_resolve!(parameters, message)

            prompt = handle_prompt(parameters:)
            validate_message_shape!(parameters:, prompt:)

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

          # A chat completion needs a turn for the model to answer, and it is the model's own
          # chat template that insists on one: Qwen's raises "No user query found in
          # messages." Left to the gateway that costs a round trip and comes back as a 400
          # whose body the caller cannot read, so it is caught here instead, while the prompt
          # is still in hand and the advice can name what to do about it.
          #
          # Presence of the turn is what is checked, not its usefulness. A template may well
          # accept an empty user message -- Qwen's does -- but a caller who sent one almost
          # never meant to, so blank content is refused rather than forwarded. Content
          # arriving as an array of parts is taken at face value, since a message carrying
          # only an image is a legitimate turn.
          def validate_message_shape!(parameters:, prompt:)
            return if parameters[:messages].any? { |message| user_turn?(message) }

            raise ObservedChatPromptError, missing_user_message_error(prompt)
          end

          def user_turn?(message)
            role = message[:role] || message["role"]
            return false unless role.to_s == "user"

            (message[:content] || message["content"]).present?
          end

          def missing_user_message_error(prompt)
            case prompt&.type
            when "text"
              "The prompt #{prompt.name.inspect} is a text prompt, so it contributes only a system message and " \
              "this request carries no turn for the model to answer. Pass a `message:`, or define " \
              "#{prompt.name.inspect} as a chat prompt in Cerebro so that it carries its own user message."
            when "chat"
              "The chat prompt #{prompt.name.inspect} contains no user message and none was supplied, so this " \
              "request carries no turn for the model to answer. Add a user message to #{prompt.name.inspect} " \
              "in Cerebro, or pass a `message:`."
            else
              "This request carries no user message, so there is no turn for the model to answer. Pass a " \
              "`message:`, or supply `parameters[:messages]` including a message with the `user` role."
            end
          end

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
            output = chat_completion.choices.first.message.to_h

            trace_attributes = {
              model: chat_completion.model,
              output:,
              usage_details: {
                prompt_tokens: chat_completion.usage.prompt_tokens,
                completion_tokens: chat_completion.usage.completion_tokens,
                total_tokens: chat_completion.usage.total_tokens,
              },
              cost_details: @base_handler.cost_details(chat_completion),
            }

            [chat_completion, trace_attributes]
          end
        end
      end
    end
  end
end
