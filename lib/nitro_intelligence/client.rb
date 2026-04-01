require "nitro_intelligence/trace"

module NitroIntelligence
  class Client
    attr_accessor :client

    def initialize(observability_project_slug: nil)
      @inference_api_key = NitroIntelligence.config.inference_api_key
      @inference_host = NitroIntelligence.config.inference_base_url
      @observability_host = NitroIntelligence.config.observability_base_url
      @observability_project_slug = observability_project_slug
      @client = OpenAI::Client.new(
        api_key: @inference_api_key,
        base_url: @inference_host
      )
      @langfuse_client = NitroIntelligence.langfuse_clients[observability_project_slug]
    end

    def chat(message: "", parameters: {})
      default_params = CUSTOM_PARAMS.index_with { |_param| nil }
                                    .merge({
                                             metadata: {},
                                             messages: [],
                                             model: NitroIntelligence.model_catalog.default_text_model.name,
                                             observability_project_slug:,
                                           })
      parameters = default_params.merge(parameters)

      parameters[:messages] = [{ role: "user", content: message }] if parameters[:messages].blank? && message.present?

      return chat_with_tracing(parameters:) if observability_available?

      client_chat(parameters:)
    end

    # We abstract the image generation for now because of usage
    # across various apis: chat/completions, image/edits, image/generations
    # Input images should be byte strings
    # Returns NitroIntelligence::ImageGeneration
    def generate_image(
      message: "",
      target_image: nil,
      reference_images: [],
      parameters: {}
    )
      image_generation = NitroIntelligence::ImageGeneration.new(message:, target_image:, reference_images:) do |config|
        config.aspect_ratio = parameters[:aspect_ratio] if parameters.key?(:aspect_ratio)
        config.model = parameters[:model] if parameters.key?(:model)
        config.resolution = parameters[:resolution] if parameters.key?(:resolution)
      end

      default_params = CUSTOM_PARAMS.index_with { |_param| nil }
                                    .merge({
                                             image_generation:,
                                             metadata: {},
                                             messages: image_generation.messages,
                                             model: image_generation.config.model,
                                             observability_project_slug:,
                                             extra_headers: {
                                               "Prefer" => "wait",
                                             },
                                             request_options: {
                                               extra_body: {
                                                 image_config: {
                                                   aspect_ratio: image_generation.config.aspect_ratio,
                                                   image_size: image_generation.config.resolution,
                                                 },
                                               },
                                             },
                                           })
      parameters = default_params.merge(parameters)

      if observability_available?
        chat_with_tracing(parameters:)
      else
        chat_completion = client_chat(parameters:)
        image_generation.parse_file(chat_completion)
      end

      image_generation
    end

    def score(trace_id:, name:, value:, id: "#{trace_id}-#{name}")
      raise ObservabilityUnavailableError, "Observability project slug not configured" unless observability_available?

      if @langfuse_client.nil?
        raise LangfuseClientNotFoundError,
              "No Langfuse client found for slug: #{observability_project_slug}"
      end

      @langfuse_client.create_score(
        id:,
        trace_id:,
        name:,
        value:,
        environment: NitroIntelligence.environment
      )
    end

    def create_dataset_item(attributes)
      HTTParty.post("#{@observability_host}/api/public/dataset-items",
                    body: attributes.to_json,
                    headers: {
                      "Content-Type" => "application/json",
                      "Authorization" => "Basic #{observability_auth_token}",
                    })
    end

  private

    attr_reader :observability_project_slug

    def current_revision
      return @current_revision if defined?(@current_revision)

      path = Rails.root.join("REVISION")
      @current_revision = File.exist?(path) ? File.read(path).strip.presence : nil
    end

    def observability_available?
      observability_project_slug.present?
    end

    def method_missing(method_name, *, &)
      @client.send(method_name, *, &)
    end

    def respond_to_missing?(method_name, include_private = false)
      @client.respond_to?(method_name, include_private) || super
    end

    def project_config
      return @project_config if @project_config.present?

      projects = NitroIntelligence.config.observability_projects
      @project_config = projects.find { |project| project["slug"] == observability_project_slug }

      if @project_config.nil?
        raise ObservabilityProjectConfigNotFoundError,
              "No observability project config found for slug: #{observability_project_slug}"
      end

      @project_config
    end

    def client_chat(parameters:)
      # When requesting an OpenAI model, OpenAI API will return a 400 because it does not ignore custom params
      @client.chat.completions.create(**parameters.except(*NitroIntelligence.omit_params))
    end

    def chat_with_tracing(parameters:)
      project = get_project(
        project_id: project_config["id"],
        observability_public_key: project_config["public_key"]
      )
      prompt = handle_prompt(parameters:, project_config:)

      instrument_tracing(prompt:, project:, parameters:)
    rescue ObservabilityProjectNotFoundError, LangfuseClientNotFoundError => e
      # We should still send the request if we have problems with observability
      NitroIntelligence.logger.warn(
        "#{self.class} - Observability configuration provided, but could not be processed. #{e}. " \
        "Sending request regardless."
      )
      client_chat(parameters:)
    end

    def handle_prompt(parameters:, project_config:)
      return if parameters[:prompt_name].blank?

      prompt_store = NitroIntelligence::PromptStore.new(
        observability_project_slug:,
        observability_public_key: project_config["public_key"],
        observability_secret_key: project_config["secret_key"]
      )
      prompt = prompt_store.get_prompt(
        prompt_name: parameters[:prompt_name],
        prompt_label: parameters[:prompt_label],
        prompt_version: parameters[:prompt_version]
      )
      prompt_variables = parameters[:prompt_variables] || {}

      if prompt.present?
        parameters[:messages] = prompt.interpolate(
          messages: parameters[:messages],
          variables: prompt_variables
        )

        parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]
      end

      prompt
    end

    def instrument_tracing(prompt:, project:, parameters:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      if @langfuse_client.nil?
        raise LangfuseClientNotFoundError,
              "No Langfuse client found for slug: #{observability_project_slug}"
      end

      default_trace_name = project["name"]
      input = parameters[:messages]
      image_generation = parameters[:image_generation]
      metadata = parameters[:metadata]

      if prompt
        metadata[:prompt_name] = prompt.name
        metadata[:prompt_version] = prompt.version
        default_trace_name = prompt.name
      end

      seed = parameters[:trace_seed]
      trace_id = NitroIntelligence::Trace.create_id(seed:) if seed.present?

      chat_completion = nil

      Langfuse.propagate_attributes(
        user_id: parameters[:user_id] || "default-user",
        metadata: metadata.transform_values(&:to_s)
      ) do
        @langfuse_client.observe(
          "llm-response",
          as_type: :generation,
          trace_id:,
          environment: NitroIntelligence.environment.to_s,
          input:,
          model: parameters[:model],
          metadata: metadata.transform_values(&:to_s)
        ) do |generation|
          generation.update_trace(
            name: parameters[:trace_name] || default_trace_name,
            release: current_revision
          )

          if prompt
            generation.update({
                                prompt: {
                                  name: prompt.name,
                                  version: prompt.version,
                                },
                              })
          end

          chat_completion = client_chat(parameters:)
          output = chat_completion.choices.first.message.to_h

          # Handle image generation media
          if image_generation
            image_generation.trace_id = generation.trace_id
            image_generation.parse_file(chat_completion)
            handle_image_generation_uploads(input, output, image_generation)
          end

          # Handle truncating any unnecessary data before storing into trace
          handle_truncation(input, output, chat_completion.model)

          generation.model = chat_completion.model
          generation.usage_details = {
            prompt_tokens: chat_completion.usage.prompt_tokens,
            completion_tokens: chat_completion.usage.completion_tokens,
            total_tokens: chat_completion.usage.total_tokens,
          }
          generation.input = input
          generation.output = output

          generation.update_trace(input:, output:)
        end
      end

      chat_completion
    end

    # Returns name and metadata
    def get_project(project_id:, observability_public_key:)
      cache_key = OBSERVABILITY_PROJECTS_CACHE_KEY_PREFIX + project_id
      cached_project = NitroIntelligence.cache.read(cache_key)
      return cached_project if cached_project.present?

      target_project = get_projects(observability_public_key:).find do |project|
        project["id"] == project_id
      end

      raise ObservabilityProjectNotFoundError, "Project with ID: #{project_id} not found" if target_project.nil?

      NitroIntelligence.cache.write(cache_key, target_project, expires_in: 12.hours)
      target_project
    end

    def get_projects(observability_public_key:)
      response = HTTParty.get("#{@observability_host}/api/public/projects",
                              headers: {
                                "Authorization" => "Basic #{observability_auth_token}",
                              })
      data = JSON.parse(response.body)["data"]
      if data.nil?
        raise(
          ObservabilityProjectNotFoundError,
          "No projects were found. Public key: #{observability_public_key || 'missing'}"
        )
      end
      data
    end

    def handle_image_generation_uploads(input, output, image_generation)
      # If we are doing image generation we should upload the media to observability manually
      upload_handler = NitroIntelligence::UploadHandler.new(@observability_host, observability_auth_token)
      upload_handler.upload(
        image_generation.trace_id,
        upload_queue: Queue.new(image_generation.files)
      )

      # Replace base64 strings with media references
      upload_handler.replace_base64_with_media_references(input)
      upload_handler.replace_base64_with_media_references(output)
    end

    def handle_truncation(_input, output, model_name)
      model = NitroIntelligence.model_catalog.lookup_by_name(model_name)

      return unless model&.omit_output_fields

      model.omit_output_fields.each do |omit_output_field|
        last_key = omit_output_field.last
        parent_keys = omit_output_field[0...-1]
        parent = parent_keys.empty? ? output : output.dig(*parent_keys)

        parent[last_key] = "[Truncated...]" if parent.is_a?(Hash) && parent.key?(last_key)
      end
    end

    def observability_auth_token
      public_key = project_config["public_key"]
      secret_key = project_config["secret_key"]
      @observability_auth_token ||= Base64.strict_encode64("#{public_key}:#{secret_key}")
    end
  end
end
