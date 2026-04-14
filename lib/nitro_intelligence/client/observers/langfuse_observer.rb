module NitroIntelligence
  module Client
    module Observers
      class LangfuseObserver
        attr_reader :project_client

        def initialize(project_client:)
          @project_client = project_client
        end

        def observe(operation_name, type:, parameters:, trace_name:, prompt: nil) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          metadata = parameters[:metadata]
          seed = parameters[:trace_seed]
          user_id = parameters[:user_id] || NitroIntelligence.configuration.observability_user_id
          trace_id = NitroIntelligence::Trace.create_id(seed:) if seed.present?

          if prompt
            metadata[:prompt_name] = prompt.name
            metadata[:prompt_version] = prompt.version
          end

          metadata = metadata.transform_values(&:to_s)

          Langfuse.propagate_attributes(
            user_id:,
            metadata:
          ) do
            @project_client.observability_client.observe(
              operation_name,
              as_type: type,
              trace_id:,
              environment: NitroIntelligence.environment.to_s,
              model: parameters[:model],
              metadata:
            ) do |generation|
              generation.update_trace(name: trace_name, release: NitroIntelligence.configuration.current_revision)
              generation.update({ prompt: { name: prompt.name, version: prompt.version } }) if prompt

              result, trace_attributes = yield(generation)

              if trace_attributes
                handle_truncation(trace_attributes[:input], trace_attributes[:output], trace_attributes[:model])

                generation.model = trace_attributes[:model] if trace_attributes[:model]
                generation.usage_details = trace_attributes[:usage_details] if trace_attributes[:usage_details]
                generation.input = trace_attributes[:input] if trace_attributes[:input]
                generation.output = trace_attributes[:output] if trace_attributes[:output]

                generation.update_trace(input: trace_attributes[:input], output: trace_attributes[:output])
              end

              result
            end
          end
        end

      private

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
      end
    end
  end
end
