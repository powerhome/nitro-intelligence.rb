require "nitro_intelligence/observability/prompt_resolver"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class ResponsesHandler
          class ObservedResponsesPromptError < StandardError; end

          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(message: "", parameters: {})
            @base_handler.validate_and_resolve!(parameters, message)

            prompt = handle_prompt(parameters:)
            ensure_input!(parameters:, prompt:)

            trace_name = parameters[:trace_name] || prompt&.name || @observer.project_client.project.slug

            @observer.observe(
              "response",
              type: :generation,
              parameters:,
              trace_name:,
              prompt:,
              input: observed_input(parameters)
            ) do |generation|
              workflow(generation:, parameters:)
            end
          end

        private

          # Each prompt type has a slot of its own here. A text prompt is the instruction the
          # model is given, and a chat prompt is the opening of the input it answers, so
          # neither has to be flattened into the other the way a message list requires.
          def handle_prompt(parameters:)
            prompt = NitroIntelligence::Observability::PromptResolver.for(
              store: @observer.project_client.project.prompt_store,
              parameters:
            )
            return nil if prompt.blank?

            variables = parameters[:prompt_variables] || {}

            case prompt.type
            when "text" then parameters[:instructions] = prompt.compile(**variables)
            when "chat" then parameters[:input] = prompt.compile(**variables) + input_items(parameters[:input])
            end

            parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]

            prompt
          end

          def input_items(input)
            return [] if input.blank?

            input.is_a?(Array) ? input : [{ role: "user", content: input }]
          end

          # An instruction alone is not something this endpoint will answer: the model's chat
          # template still wants a turn, and the two ways of having none -- omitting `input`
          # and sending an empty one -- fail as a 500 and as a silently invented turn
          # respectively. Both are refused here instead.
          def ensure_input!(parameters:, prompt:)
            return if parameters[:input].present?

            raise ObservedResponsesPromptError, missing_input_error(prompt)
          end

          def missing_input_error(prompt)
            case prompt&.type
            when "text"
              "The prompt #{prompt.name.inspect} is a text prompt, so it supplies this request's " \
              "`instructions` and nothing for the model to answer. Pass a `message:`, or define " \
              "#{prompt.name.inspect} as a chat prompt in Cerebro so that it carries its own input."
            when "chat"
              "The chat prompt #{prompt.name.inspect} produced no input and none was supplied. Add a " \
              "user message to #{prompt.name.inspect} in Cerebro, or pass a `message:`."
            else
              "This request carries no `input`, so there is nothing for the model to answer. Pass a " \
              "`message:`, or supply `parameters[:input]`."
            end
          end

          # The instructions are recorded alongside the input so that a trace shows the whole of
          # what the model was given, as a chat generation's message list does.
          def observed_input(parameters)
            instructions = parameters[:instructions]
            return parameters[:input] if instructions.blank?

            { instructions:, input: parameters[:input] }
          end

          def workflow(generation:, parameters:)
            response = @base_handler.perform_request(parameters:, correlation_trace_id: generation.trace_id)

            trace_attributes = {
              model: response.model,
              output: output_of(response),
              usage_details: usage_details(response.usage),
              cost_details: @base_handler.cost_details(response),
            }

            [response, trace_attributes]
          end

          # `output_text` is the message alone. This endpoint returns everything else the model
          # produced -- the reasoning that preceded the message, and any tool it decided to
          # call -- as sibling items rather than fields of it, so recording only the message
          # drops them from the trace. A response that calls a tool has no message at all, and
          # would otherwise be recorded as empty.
          #
          # The parts are recorded under the names a chat generation gives them, so a trace
          # reads the same whichever endpoint served it.
          def output_of(response)
            reasoning = reasoning_text(response)
            tool_calls = tool_calls_of(response)
            return response.output_text if reasoning.blank? && tool_calls.empty?

            output = { content: response.output_text }
            output[:reasoning_content] = reasoning if reasoning.present?
            output[:tool_calls] = tool_calls if tool_calls.any?
            output
          end

          def tool_calls_of(response)
            response.output.filter_map do |call|
              next unless call.type == :function_call

              {
                id: call.call_id || call.id,
                type: "function",
                function: { name: call.name, arguments: call.arguments },
              }
            end
          end

          def reasoning_text(response)
            items = response.output.select { |item| item.type == :reasoning }
            return nil if items.empty?

            items.flat_map { |item| Array(item.content) + Array(item.summary) }
                 .filter_map(&:text).join("\n").presence
          end

          # Reasoning is counted separately from the output it precedes, and recording it keeps
          # the share of a generation spent thinking visible rather than folded into the output
          # total.
          #
          # The three totals are named as the observability platform names them, rather than as
          # the endpoint does. The platform translates the endpoint's own names only while every
          # key is one it recognises; a custom key alongside them turns the whole hash into
          # opaque counters, which it then sums into a total of its own -- counting the total
          # twice. Naming them natively keeps the breakdown intact and leaves the reasoning
          # count free to sit beside it.
          def usage_details(usage)
            details = {
              input: usage.input_tokens,
              output: usage.output_tokens,
              total: usage.total_tokens,
            }

            reasoning_tokens = usage.output_tokens_details&.reasoning_tokens
            details[:reasoning_tokens] = reasoning_tokens if reasoning_tokens

            details
          end
        end
      end
    end
  end
end
