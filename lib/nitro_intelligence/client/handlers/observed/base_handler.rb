module NitroIntelligence
  module Client
    module Handlers
      module Observed
        # Wraps a handler's request in an observation recorded to the observer's Cerebro project.
        class BaseHandler
          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

        private

          def project
            @observer.project_client.project
          end
        end
      end
    end
  end
end
