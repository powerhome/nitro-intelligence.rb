RSpec.describe NitroIntelligence::Audio do
  let(:byte_string) { "fake_audio_bytes" }

  # Helper to generate a mocked file object
  def mock_audio_file(extension)
    double("File", read: byte_string, to_path: "recording.#{extension}")
  end

  describe "#initialize" do
    let(:file_mock) { mock_audio_file("mp3") }
    let(:audio) { described_class.new(file_mock) }

    it "reads the file and sets basic attributes correctly" do
      expect(audio.byte_string).to eq(byte_string)
      expect(audio.base64).to eq(Base64.strict_encode64(byte_string))
      expect(audio.file_type).to eq("audio")
      expect(audio.file_extension).to eq("mp3")
      expect(audio.mime_type).to eq("audio/mp3")
    end
  end

  describe "mime_type mapping (#determine_mime_type)" do
    it "maps mp4-related extensions correctly" do
      %w[m4a m4b m4r m4p mp4].each do |ext|
        audio = described_class.new(mock_audio_file(ext))
        expect(audio.mime_type).to eq("audio/mp4")
      end
    end

    it "maps mp3-related extensions correctly" do
      %w[mp3 mpga mp2 mp1].each do |ext|
        audio = described_class.new(mock_audio_file(ext))
        expect(audio.mime_type).to eq("audio/mp3")
      end
    end

    it "maps wav extensions correctly" do
      %w[wav wave].each do |ext|
        audio = described_class.new(mock_audio_file(ext))
        expect(audio.mime_type).to eq("audio/wav")
      end
    end

    it "maps webm extensions correctly" do
      %w[webm weba].each do |ext|
        audio = described_class.new(mock_audio_file(ext))
        expect(audio.mime_type).to eq("audio/webm")
      end
    end

    it "maps ogg-related extensions correctly" do
      %w[ogg spx].each do |ext|
        audio = described_class.new(mock_audio_file(ext))
        expect(audio.mime_type).to eq("audio/ogg")
      end
    end

    it "maps specific explicit extensions correctly" do
      expect(described_class.new(mock_audio_file("oga")).mime_type).to eq("audio/oga")
      expect(described_class.new(mock_audio_file("aac")).mime_type).to eq("audio/aac")
      expect(described_class.new(mock_audio_file("flac")).mime_type).to eq("audio/flac")
      expect(described_class.new(mock_audio_file("opus")).mime_type).to eq("audio/opus")
    end

    it "defaults to 'audio/extension' for unknown extensions" do
      audio = described_class.new(mock_audio_file("xyz"))
      expect(audio.mime_type).to eq("audio/xyz")
    end

    it "handles uppercase extensions by downcasing them" do
      audio = described_class.new(mock_audio_file("MP3"))
      expect(audio.mime_type).to eq("audio/mp3")
    end
  end
end
