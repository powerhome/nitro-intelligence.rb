require "base64"
require "nitro_intelligence/observability/prompt_store"

module NitroIntelligence
  module Observability
    class Project
      class NotFoundError < StandardError; end

      attr_reader :slug, :id, :public_key, :secret_key, :auth_token, :prompt_store

      def initialize(slug:, id:, public_key:, secret_key:, **_kwargs)
        @slug = slug
        @id = id
        @public_key = public_key
        @secret_key = secret_key
        @auth_token = Base64.strict_encode64("#{public_key}:#{secret_key}")
        @prompt_store = PromptStore.new(
          observability_project_slug: slug,
          observability_public_key: public_key,
          observability_secret_key: secret_key
        )
      end

      def self.find_by_slug(slug:)
        project_config = NitroIntelligence.config.observability_projects.find { |project| project["slug"] == slug }

        return new(**project_config.to_h.transform_keys(&:to_sym)) if project_config

        nil
      end
    end
  end
end
