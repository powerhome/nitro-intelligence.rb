require_relative "e2e_helper"

RSpec.describe "NitroIntelligence::Client#generate_image", :e2e do
  include_context "with a traced request"

  let(:media_reference) { %r{@@@langfuseMedia:type=image/[^|]+\|id=[^|]+\|source=bytes@@@} }
  let(:image_parameters) { { aspect_ratio: "1:1", resolution: "512", **trace_parameters } }

  def expect_image(result)
    expect(result.generated_image.mime_type).to start_with("image/")
    expect(result.generated_image.width).to be_positive
    expect(result.generated_image.height).to be_positive
    expect(result.trace_id).to eq(trace_id)
  end

  def expect_image_generation(generation, result)
    expect_request(generation, name: "image-generation")
    expect(generation["id"]).to eq(result.observation_id)
    expect(generation["model"]).to eq(E2eHelpers::IMAGE_MODEL)
    expect(generation.dig("usageDetails", "total")).to be_positive
    # The completion behind the image is not returned to the caller, so the cost is checked for presence.
    expect(generation.dig("costDetails", "total")).to be_positive
  end

  it "returns a generated image, and records it with the image uploaded to Cerebro" do
    result = client.generate_image(message: "A plain red square on a white background.", parameters: image_parameters)

    expect_image(result)

    generation = recorded_request("image-generation")
    expect_image_generation(generation, result)
    expect(CerebroReader.parse(generation["input"])).to eq(
      [{ "role" => "user", "content" => [{ "type" => "text", "text" => "A plain red square on a white background." }] }]
    )
    # The image is uploaded to Cerebro, and the output refers to it in place of its base64.
    expect(generation["output"].scan(media_reference).size).to eq(1)
    expect(generation["output"]).not_to include("base64,")
  end

  it "edits a target image after a reference image, and records all three uploaded to Cerebro" do
    target = drawn_image("rectangle 64,64 192,192", fill: "red")
    reference = drawn_image("circle 128,128 128,48", fill: "blue")

    result = client.generate_image(
      message: "Repaint the square in the first image the color of the circle in the second.",
      target_image: target, reference_images: [reference], parameters: { resolution: "512", **trace_parameters }
    )

    expect_image(result)

    generation = recorded_request("image-generation")
    expect_image_generation(generation, result)
    # The target and reference images are uploaded too, and the input refers to them.
    expect(generation["input"].scan(media_reference).size).to eq(2)
    expect(generation["input"]).not_to include("base64,")
    expect(generation["output"].scan(media_reference).size).to eq(1)
  end

  context "with a text prompt managed in Cerebro" do
    let(:prompt_name) { "nitro-intelligence.rb e2e image" }
    let!(:version) do
      cerebro.prompt_version(name: prompt_name, type: "text", prompt: "Draw on a {{background}} background.",
                             config: {}, labels: ["production"])
    end

    it "draws with the prompt as the system message, and links the generation to its version" do
      result = client.generate_image(
        message: "A plain red square.",
        parameters: { prompt_name:, prompt_variables: { background: "white" }, **image_parameters }
      )

      expect_image(result)

      generation = recorded_request("image-generation")
      expect_image_generation(generation, result)
      expect(generation).to include("promptName" => prompt_name, "promptVersion" => version)
      expect(CerebroReader.parse(generation["input"]).first).to eq(
        "role" => "system", "content" => "Draw on a white background."
      )
    end
  end

  context "with a project that masks content" do
    it "records the generation's usage and cost but none of its content, and uploads no image" do
      result = masked_client.generate_image(message: "A plain red square on a white background.",
                                            parameters: image_parameters)

      expect_image(result)

      generation = recorded_request("image-generation")
      expect_image_generation(generation, result)
      expect_masked(generation)
    end
  end
end
