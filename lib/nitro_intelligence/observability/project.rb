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
      # @return [String] the Base64 `public_key:secret_key` credential for Cerebro's public API,
      #   without the scheme: send it as `Authorization: Basic #{auth_token}`
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

      # Fetches one of the project's prompts, without making a model call: to read its `config`, or to
      # compile its text for a request of your own.
      #
      # A prompt fetched by label is cached for five minutes, and by version indefinitely. If Cerebro
      # cannot be reached, a label lookup falls back to the last prompt fetched for that label, however
      # old. To use the same prompt for several steps, fetch it once and ask for its `version` in the
      # requests that follow, so that a label moved in between cannot mix two versions.
      #
      # @param name [String] the prompt's name in Cerebro
      # @param label [String, nil] the label to fetch, `"production"` when neither it nor `version`
      #   is given
      # @param version [Integer, nil] the version to fetch, taking precedence over `label`
      # @return [Prompt]
      # @raise [PromptStore::ObservabilityPromptNotFoundError] when the prompt, at that label or
      #   version, does not exist
      # @raise [PromptStore::ObservabilityPromptError] when Cerebro fails to return the prompt
      # @example
      #   prompt = project.prompt("Page Finder Search")
      #   prompt.config[:candidates] # => 50
      def prompt(name, label: nil, version: nil)
        prompt = prompt_store.get_prompt(prompt_name: name, prompt_label: label, prompt_version: version)
        raise PromptStore::ObservabilityPromptNotFoundError, "Prompt: #{name} Not Found" if prompt.nil?

        prompt
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
