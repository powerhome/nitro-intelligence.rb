require "nitro_intelligence/client/factory"

module NitroIntelligence
  # Inference through the inference gateway: chat, image generation and editing, audio
  # transcription and text-to-speech. See the README's "Basic Usage".
  module Client
    # Builds a client, which records every request in Cerebro when given a project to report to.
    #
    # A project slug that `observability_projects` does not configure, or that Cerebro does not
    # know, logs a warning and gives a client without observability rather than raising.
    #
    # @param observability_project_slug [String, nil] the Cerebro project to record requests in, and
    #   to fetch prompts from
    # @param inference_max_retries [Integer, nil] overrides the configured `inference_max_retries`
    #   for this client
    # @param inference_timeout [Numeric, nil] overrides the configured `inference_timeout` for this
    #   client, in seconds
    # @return [Client::Base]
    # @example
    #   client = NitroIntelligence::Client.new(observability_project_slug: "my-feature-project")
    #   client.chat(message: "Why is the sky blue?")
    def self.new(observability_project_slug: nil, inference_max_retries: nil, inference_timeout: nil)
      Factory.new(observability_project_slug:, inference_max_retries:, inference_timeout:).build
    end

    # @api private
    def self.validate_model(model)
      raise ArgumentError, "Unsupported model: '#{model}'" unless NitroIntelligence.model_catalog.exists?(model)
    end
  end
end
