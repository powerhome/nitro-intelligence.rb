module NitroIntelligence
  module Client
    module Handlers
      class BaseHandler
        def initialize(client:)
          @client = client
        end

      private

        def add_request_headers(parameters, headers)
          request_options = (parameters[:request_options] ||= {})
          (request_options[:extra_headers] ||= {}).merge!(headers)
          parameters
        end
      end
    end
  end
end
