# Nitro Intelligence

The entrypoint to everything AI.

This component aims to consolidate and standardize AI features implemented in the host application.

## Configuration

`NitroIntelligence` is configured via an initializer in the host application. All external dependencies
(e.g. inference API credentials, observability settings) must be injected at boot time:

```ruby
NitroIntelligence.configure do |config|
  # Standard Rails integrations
  config.logger         = Rails.logger           # Logger instance
  config.environment    = Rails.env              # e.g. "production", "test"
  config.cache_provider = Rails.cache            # ActiveSupport cache store

  # Inference (LLM) settings
  config.inference_api_key  = "..."              # API key for the inference service
  config.inference_base_url = "https://..."      # Base URL for the inference service

  # Observability (Langfuse) settings
  config.observability_base_url = "https://..."  # Base URL for the observability service
  config.observability_projects = [              # Array of project credential hashes
    {
      "slug"       => "my-feature-project",
      "id"         => "project-id",
      "public_key" => "pk-...",
      "secret_key" => "sk-...",
    },
  ]

  # Agent server settings (optional)
  config.agent_server_config = {}                # Hash of AgentServer keyword arguments
end
```

### Configuration Keys

| Key | Type | Default | Description |
|---|---|---|---|
| `logger` | `Logger` | `Logger.new($stdout)` | Logger used for diagnostic output |
| `environment` | `String` | `"test"` | Runtime environment name |
| `cache_provider` | cache store | `NullCache` | ActiveSupport-compatible cache store |
| `inference_api_key` | `String` | `""` | API key for the LLM inference service |
| `inference_base_url` | `String` | `""` | Base URL for the LLM inference service |
| `observability_base_url` | `String` | `""` | Base URL for the Langfuse observability service |
| `observability_projects` | `Array<Hash>` | `[]` | Langfuse project credentials (slug, id, public_key, secret_key) |
| `agent_server_config` | `Hash` | `{}` | Credentials for `AgentServer.new`. Expected keys: `base_url` (String) — HTTP base URL of the agent server; `api_key` (String) — bearer token; `user_id` (String, default: `"default-user"`) — caller identity |

## Basic Usage

### OpenAI API/LLM Requests

A simple LLM call can be invoked as follows:

```ruby
client = NitroIntelligence::Client.new
client.chat(message: "Why is the sky blue?")
content = result.choices.first&.message&.content
```

This component handles setting defaults for most things, such as model, host, keys, etc.

You may also use [`openai-ruby`](https://github.com/openai/openai-ruby) compatible syntax with this wrapper by passing the parameters keyword in. For example:

```ruby
client = NitroIntelligence::Client.new
client.chat(parameters: { model: "meta-llama/Llama-3.1-8B-Instruct", messages: [{ role: "user", content: "Why is the sky blue?" }]})
```


#### Providing Parameters

Parameters such as 'max_tokens' and 'temperature' can be passed in under the `parameters` key.

```ruby
client = NitroIntelligence::Client.new
client.chat(parameters: { model: "meta-llama/Llama-3.1-8B-Instruct", max_tokens: 1000, temperature: 0.7, messages: [{ role: "user", content: "Why is the sky blue?" }]})
```

For a full list of supported parameters, see the [API reference here](https://developers.openai.com/api/reference/resources/completions/methods/create).

### Image Editing and Generation

Nitro Intelligence can be used for image editing and generation

Basic examples of usage:

#### Image Generation

```ruby
client = NitroIntelligence::Client.new
result = client.generate_image(message: "Create an image of a bear installing a window.")
```

`result` is a `NitroIntelligence::ImageGeneration` object, and the generated image can be accessed via `result.generated_image` which returns a `NitroIntelligence::Image`.

You may write the file to disk:

```ruby
File.binwrite("my_generated_image.#{result.generated_image.file_extension}", result.generated_image.byte_string)
```

#### Image Editing and Uploading Reference Images

To edit an image, provide your source image as a byte string, along with any references you would like to include.

```ruby
client = NitroIntelligence::Client.new
house = File.binread("./house.jpg")
siding = File.binread("./siding.png")
result = client.generate_image(message: "Replace the siding in the image of the house with the new siding I have provided.", target_image: house, reference_images: [siding])
```

#### Using Prompts

See Observability[## Observability] for more details. Basic usage looks like:

```ruby
client = NitroIntelligence::Client.new(observability_project_slug: "sample-project-slug")
house = File.binread("./house.jpg")
siding = File.binread("./siding.png")
result = client.generate_image(target_image: house, reference_images: [siding], parameters: {prompt_name: "Sample Prompt Name"})
```

#### Image Configuration

You can specify parameters such as model to use, aspect ratio and resolution via the `parameters` key:

```ruby
client = NitroIntelligence::Client.new
result = client.generate_image(message: "Create an image of a bear installing a window.", parameters: {aspect_ratio: "4:3", resolution: "512"})
```

## Observability

### Setup

If your feature is setup for observability, simply pass the observability project and desired prompt name in when invoking requests. It is also preferable to pass in a source and any other useful metadata for later debugging. For example:

```ruby
client = NitroIntelligence::Client.new(observability_project_slug: "fake-feature-project")
client.chat(
  message: "Why is the sky blue?",
  parameters: {
    prompt_name: "My Prompt",
    # prompt_label: "debug",
    # prompt_version: "v2",
    metadata: {
      source: self.class,
    },
  }
)
```

If no `prompt_label` or `prompt_version` is provided, the 'production' prompt is used by default.

### Custom Trace Names

To provide custom trace names to the observability platform, you can pass 'trace_name' in parameters. Example:

```ruby
client = NitroIntelligence::Client.new(observability_project_slug: "fake-feature-project")
client.chat(
  message: "Why is the sky blue?",
  parameters: {
    prompt_name: "My Prompt",
    metadata: {
      source: self.class,
    },
    trace_name: "custom-trace-name"
  }
)
```

### Prompt Variables and Config

Prompts are often created with "variables". These variables can be supplied and compiled into the prompt. For example:

```ruby
client = NitroIntelligence::Client.new(observability_project_slug: "fake-feature-project")
client.chat(
  message: "Where is the appointment?",
  parameters: {
    prompt_name: "My Prompt With Variables",
    prompt_variables: {
      appointment_id: "1234",
    },
    metadata: {
      source: self.class,
    },
  }
)
```

Prompts can be created with a "config" JSON object. This config stores structured data such as model parameters (like model name, temperature), function/tool parameters, or JSON schemas.

The prompt config is merged into your chat request by default. The prompt config object is merged into the "parameters" hash, overriding any existing keys.

Consider this prompt config:

```json
{
  "model": "gpt-4o-mini"
}
```

Invoking this request would result in "gpt-4o-mini" being used as the model, even if supplied manually:

```ruby
client = NitroIntelligence::Client.new(observability_project_slug: "fake-feature-project")
client.chat(
  message: "Where is the appointment?",
  parameters: {
    model: "meta-llama/Llama-3.1-8B-Instruct", # Will not be used, will be overridden by config "gpt-4o-mini"
    prompt_name: "My Prompt With Variables",
    prompt_variables: {
      appointment_id: "1234",
    },
    metadata: {
      source: self.class,
    },
  }
)
```

To disable the prompt config entirely, which may be useful for debugging/testing, you can supply the "prompt_config_disabled" keyword. For example:

```ruby
client = NitroIntelligence::Client.new(observability_project_slug: "fake-feature-project")
client.chat(
  message: "Where is the appointment?",
  parameters: {
    model: "meta-llama/Llama-3.1-8B-Instruct", # This will now be used since "prompt_config_disabled" is true
    prompt_name: "My Prompt With Variables",
    prompt_variables: {
      appointment_id: "1234",
    },
    prompt_config_disabled: true,
    metadata: {
      source: self.class,
    },
  }
)
```
