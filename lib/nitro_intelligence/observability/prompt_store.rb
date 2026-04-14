require "base64"
require "cgi"
require "httparty"

require "nitro_intelligence/observability/prompt"

module NitroIntelligence
  module Observability
    class PromptStore
      OBSERVABILITY_PROMPTS_CACHE_KEY_PREFIX = "nitro_intelligence_observability_prompts_".freeze

      class ObservabilityPromptError < StandardError; end
      class ObservabilityPromptNotFoundError < StandardError; end

      def initialize(observability_project_slug:, observability_public_key:, observability_secret_key:)
        @observability_project_slug = observability_project_slug
        @observability_public_key = observability_public_key
        @observability_secret_key = observability_secret_key
        @observability_host = NitroIntelligence.config.observability_base_url
      end

      def get_prompt(prompt_name:, prompt_label: nil, prompt_version: nil)
        safe_prompt_name = CGI.escapeURIComponent(prompt_name)
        prompt = nil

        if prompt_version.present?
          prompt = get_prompt_by_version(safe_prompt_name:, prompt_version:)
        else
          prompt_label = "production" if prompt_label.nil?
          prompt = get_prompt_by_label(safe_prompt_name:, prompt_label:)
        end

        prompt = Prompt.new(**prompt) if prompt.present?

        prompt
      end

    private

      def get_prompt_by_label(safe_prompt_name:, prompt_label:)
        cache_key = "#{OBSERVABILITY_PROMPTS_CACHE_KEY_PREFIX}#{@observability_project_slug}_" \
                    "#{safe_prompt_name}_#{prompt_label}"
        if (cached_prompt = NitroIntelligence.cache.read(cache_key)).present?
          return cached_prompt
        end

        NitroIntelligence.logger.info(
          "#{self.class} - Prompt label cache miss. Fetching prompt: #{safe_prompt_name} - #{prompt_label}"
        )
        get_prompt_request(safe_prompt_name:, prompt_url_params: "label=#{prompt_label}")
      rescue => e
        if (rolling_cached_prompt = NitroIntelligence.cache.read("#{cache_key}_rolling")).present?
          NitroIntelligence.logger.warn(
            "#{self.class} #{e} - Using rolling cached prompt: #{safe_prompt_name} - #{prompt_label}"
          )
          return rolling_cached_prompt
        end

        raise e
      end

      def get_prompt_by_version(safe_prompt_name:, prompt_version:)
        cache_key = "#{OBSERVABILITY_PROMPTS_CACHE_KEY_PREFIX}#{@observability_project_slug}_" \
                    "#{safe_prompt_name}_#{prompt_version}"

        if (cached_prompt = NitroIntelligence.cache.read(cache_key)).present?
          return cached_prompt
        end

        NitroIntelligence.logger.info(
          "#{self.class} - Prompt version cache miss. Fetching prompt: #{safe_prompt_name} - #{prompt_version}"
        )
        get_prompt_request(safe_prompt_name:, prompt_url_params: "version=#{prompt_version}")
      end

      def get_prompt_request(safe_prompt_name:, prompt_url_params:)
        auth_token = Base64.strict_encode64("#{@observability_public_key}:#{@observability_secret_key}")
        response = HTTParty.get(
          "#{@observability_host}/api/public/v2/prompts/#{safe_prompt_name}?#{prompt_url_params}",
          headers: {
            "Authorization" => "Basic #{auth_token}",
          }
        )

        if response.code != 200
          raise ObservabilityPromptNotFoundError, "Prompt: #{safe_prompt_name} Not Found" if response.code == 404

          raise ObservabilityPromptError, response.body
        end

        prompt = JSON.parse(response.body, symbolize_names: true)
        write_prompt_caches(safe_prompt_name:, prompt:)
        prompt
      end

      def write_prompt_caches(safe_prompt_name:, prompt:)
        # Write versioned cache key
        version_cache_key = "#{OBSERVABILITY_PROMPTS_CACHE_KEY_PREFIX}#{@observability_project_slug}_" \
                            "#{safe_prompt_name}_#{prompt[:version]}"
        NitroIntelligence.cache.write(version_cache_key, prompt, expires_in: nil)

        # Store all versions in an array cache per label
        prompt[:labels].each do |label|
          label_cache_key = "#{OBSERVABILITY_PROMPTS_CACHE_KEY_PREFIX}#{@observability_project_slug}_" \
                            "#{safe_prompt_name}_#{label}"
          NitroIntelligence.cache.write(label_cache_key, prompt, expires_in: 5.minutes)
          NitroIntelligence.cache.write("#{label_cache_key}_rolling", prompt, expires_in: nil)
        end
      end
    end
  end
end
