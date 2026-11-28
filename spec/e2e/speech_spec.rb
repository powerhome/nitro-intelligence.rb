require_relative "e2e_helper"

RSpec.describe "NitroIntelligence::Client#text_to_speech and #transcribe_audio", :e2e do
  include_context "with a traced request"

  let(:sentence) { "The quick brown fox jumps over the lazy dog." }
  # Guides the transcription with the words it should expect.
  let(:hint) { "A pangram about a fox and a dog." }

  # Speaks the sentence, then transcribes what was spoken, both in the one trace. Returns the audio and
  # the transcription.
  def round_trip(client, speech_parameters: {}, transcription_parameters: {}, message: hint)
    audio = client.text_to_speech(message: sentence, parameters: { **speech_parameters, **trace_parameters })

    transcription = Tempfile.create(["speech", ".wav"], binmode: true) do |file|
      file.write(audio.string)
      file.rewind
      client.transcribe_audio(audio_file: file, message:,
                              parameters: { **transcription_parameters, **trace_parameters })
    end
    [audio, transcription]
  end

  def expect_speech(speech, audio)
    expect_request(speech, name: "text-to-speech")
    expect(speech["model"]).to eq(E2eHelpers::TEXT_TO_SPEECH_MODEL)
    expect_cost(speech, gateway_cost(audio))
  end

  def expect_recognition(recognition, transcription)
    expect_request(recognition, name: "audio-transcription")
    expect(recognition["model"]).to eq(E2eHelpers::AUDIO_TRANSCRIPTION_MODEL)
    # The model reports how long the audio was rather than how many tokens it took.
    expect(recognition["usageDetails"]).to include("input_audio_seconds" => transcription.usage.seconds.ceil)
    expect_cost(recognition, gateway_cost(transcription))
  end

  it "speaks text that transcribes back to the same words, and records both requests in one trace" do
    audio, transcription = round_trip(client)

    expect(words(transcription.text)).to include("quick", "brown", "fox", "lazy", "dog")

    observations = recorded_trace("text-to-speech", "audio-transcription")

    speech = observation_named(observations, "text-to-speech")
    expect_speech(speech, audio)
    expect(CerebroReader.parse(speech["input"])).to eq(sentence)
    # The audio is uploaded to Cerebro, and the output refers to it.
    expect(CerebroReader.parse(speech["output"]))
      .to match(%r{\A@@@langfuseMedia:type=audio/[^|]+\|id=[^|]+\|source=bytes@@@\z})

    recognition = observation_named(observations, "audio-transcription")
    expect_recognition(recognition, transcription)
    expect(CerebroReader.parse(recognition["input"])).to eq(hint)
    expect(CerebroReader.parse(recognition["output"])).to eq(transcription.text)
  end

  context "with text prompts managed in Cerebro" do
    let(:speech_prompt) { "nitro-intelligence.rb e2e speech" }
    let(:transcription_prompt) { "nitro-intelligence.rb e2e transcription" }
    let!(:speech_version) do
      cerebro.prompt_version(name: speech_prompt, type: "text", prompt: "Read this {{manner}}.", config: {},
                             labels: ["production"])
    end
    let!(:transcription_version) do
      cerebro.prompt_version(name: transcription_prompt, type: "text", prompt: "A pangram about a {{animal}}",
                             config: {}, labels: ["production"])
    end

    it "speaks with the speech prompt's instructions, transcribes with the transcription prompt, and links both" do
      audio, transcription = round_trip(
        client,
        speech_parameters: { prompt_name: speech_prompt, prompt_variables: { manner: "calmly" } },
        transcription_parameters: { prompt_name: transcription_prompt, prompt_variables: { animal: "fox" } },
        message: "and a dog."
      )

      expect(words(transcription.text)).to include("quick", "brown", "fox", "lazy", "dog")

      observations = recorded_trace("text-to-speech", "audio-transcription")

      speech = observation_named(observations, "text-to-speech")
      expect_speech(speech, audio)
      expect(speech).to include("promptName" => speech_prompt, "promptVersion" => speech_version)

      recognition = observation_named(observations, "audio-transcription")
      expect_recognition(recognition, transcription)
      expect(recognition).to include("promptName" => transcription_prompt, "promptVersion" => transcription_version)
      # The compiled prompt leads the caller's message.
      expect(CerebroReader.parse(recognition["input"])).to eq("A pangram about a fox and a dog.")
    end
  end

  context "with a project that masks content" do
    it "records both requests' usage and cost but neither's content, and uploads no audio" do
      audio, transcription = round_trip(masked_client)

      expect(words(transcription.text)).to include("quick", "brown", "fox", "lazy", "dog")

      observations = recorded_trace("text-to-speech", "audio-transcription")

      speech = observation_named(observations, "text-to-speech")
      expect_speech(speech, audio)
      expect_masked(speech)

      recognition = observation_named(observations, "audio-transcription")
      expect_recognition(recognition, transcription)
      expect_masked(recognition)
    end
  end
end
