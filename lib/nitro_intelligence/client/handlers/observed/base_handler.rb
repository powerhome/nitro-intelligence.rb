require "nitro_intelligence/observability/prompt_resolver"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        # Wraps a handler's request in an observation recorded to the observer's Cerebro project.
        #
        # @api private
        class BaseHandler
          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

        private

          def project
            @observer.project_client.project
          end

          # For a request whose prompt is its `instruction`, as an embedding or a rerank's is: the
          # named text prompt, compiled, becomes the instruction. Its config is not merged into the
          # request, since an embedding model taken from it would make vectors that cannot be
          # compared with the ones already stored; an application reads the config with
          # Client::Base#prompt.
          def resolve_instruction_prompt(parameters)
            if parameters[:instruction].present? && names_prompt?(parameters)
              raise ArgumentError,
                    "Pass either an instruction or a prompt_name, not both: the prompt is the instruction"
            end

            prompt = NitroIntelligence::Observability::PromptResolver.for(store: project.prompt_store, parameters:)
            return nil if prompt.nil?

            unless prompt.type == "text"
              raise ArgumentError, "The prompt #{prompt.name.inspect} is a #{prompt.type} prompt, but an instruction " \
                                   "comes only from a text prompt"
            end

            parameters[:instruction] = prompt.compile(**(parameters[:prompt_variables] || {}))
            prompt
          end

          def names_prompt?(parameters)
            parameters[:prompt_name].present? || parameters[:prompt_fallback_name].present?
          end
        end
      end
    end
  end
end
