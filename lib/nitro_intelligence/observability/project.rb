require "base64"
require "nitro_intelligence/observability/prompt_store"

module NitroIntelligence
  # Cerebro, the Langfuse deployment observed requests are recorded in.
  module Observability
    # A Cerebro project `observability_projects` configures. Use it to reach Cerebro's API, or to
    # link to the project's traces, where this gem does not.
    class Project
      # Raised by {ProjectClientRegistry#fetch} when `observability_projects` does not configure the
      # project.
      class NotFoundError < StandardError; end

      # @api private
      # Recorded in place of anything a masked project would otherwise send to Cerebro.
      MASKED_CONTENT = "[masked]".freeze

      # @return [String] the project's id in Cerebro, as in its URLs:
      #   `"#{config.observability_base_url}/project/#{id}/traces/#{trace_id}"`
      attr_reader :id
      # @return [String] the `Authorization: Basic` credential for Cerebro's public API
      attr_reader :auth_token
      # @api private
      attr_reader :slug, :public_key, :secret_key, :prompt_store

      # @api private
      def initialize(slug:, id:, public_key:, secret_key:, mask_content: false, **_kwargs)
        @slug = slug
        @id = id
        @public_key = public_key
        @secret_key = secret_key
        @auth_token = Base64.strict_encode64("#{public_key}:#{secret_key}")
        @mask_content = mask_content == true
        @prompt_store = PromptStore.new(
          observability_project_slug: slug,
          observability_public_key: public_key,
          observability_secret_key: secret_key
        )
      end

      # @api private
      def mask_content?
        @mask_content
      end

      # @api private
      #
      # Replaces the whole value rather than fields within it: the shape of a response
      # varies by provider, and redacting named fields is what let reasoning leak
      # through the gateway's own redaction. Absence stays absence, so an observation
      # that never had an output does not gain one.
      def mask(value)
        return value if !mask_content? || value.nil?

        MASKED_CONTENT
      end

      # The project `observability_projects` configures under `slug`.
      #
      # @param slug [String]
      # @return [Project, nil] nil when no project is configured under `slug`
      def self.find_by_slug(slug:)
        project_config = NitroIntelligence.config.observability_projects.find { |project| project["slug"] == slug }

        return new(**project_config.to_h.transform_keys(&:to_sym)) if project_config

        nil
      end
    end
  end
end
