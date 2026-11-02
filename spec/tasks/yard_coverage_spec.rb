require "yard"
require_relative "../../tasks/yard_coverage"

RSpec.describe YardCoverage do
  def objects(source)
    YARD::Registry.clear
    YARD.parse_string(source)
    YARD::Registry.all.to_h { |object| [object.path, described_class.undocumented?(object)] }
  ensure
    YARD::Registry.clear
  end

  it "counts what YARD documents on its own as undocumented" do
    expect(objects(<<~RUBY)).to include(
      # A class.
      class Foo
        attr_reader :reader
        attr_accessor :accessor
        def initialize(value); end
        def predicate?; end
      end
    RUBY
      "Foo#reader" => true,
      "Foo#accessor" => true,
      "Foo#accessor=" => true,
      "Foo#initialize" => true,
      "Foo#predicate?" => true
    )
  end

  it "counts comments and directives, including ones with only tags, as documentation" do
    expect(objects(<<~RUBY)).to eq(
      # A class.
      class Foo
        # @return [String] a reader
        attr_accessor :reader
        # Builds one.
        def initialize(value); end
        # @return [Boolean] whether it is
        def predicate?; end
        # @!method delegated
        #   A delegated method.
        delegate :delegated, to: :other
      end
    RUBY
      "Foo" => false,
      "Foo#reader" => false,
      "Foo#reader=" => false,
      "Foo#initialize" => false,
      "Foo#predicate?" => false,
      "Foo#delegated" => false
    )
  end

  it "counts an undocumented class as undocumented" do
    expect(objects("class Foo; end")).to eq("Foo" => true)
  end

  it "counts a docstring holding only an @api tag as undocumented" do
    expect(objects(<<~RUBY)).to eq("Foo" => true)
      # @api public
      class Foo; end
    RUBY
  end

  it "counts what YARD writes for an undocumented Struct member as undocumented" do
    expect(objects(<<~RUBY)).to include("Foo#status" => true, "Foo#status=" => true)
      # A struct.
      Foo = Struct.new(:status)
    RUBY
  end

  describe ".hidden?" do
    def hidden(source)
      YARD::Registry.clear
      YARD.parse_string(source)
      YARD::Registry.all.to_h { |object| [object.path, described_class.hidden?(object)] }
    ensure
      YARD::Registry.clear
    end

    it "hides what a private namespace holds, unless it marks itself public" do
      source = <<~RUBY
        # @api private
        class Foo
          # A lookup.
          Lookup = Struct.new(:name)
          # @api public
          class Error < StandardError; end
        end
      RUBY
      expect(hidden(source)).to eq(
        "Foo" => true, "Foo::Lookup" => true, "Foo::Lookup#name" => true, "Foo::Lookup#name=" => true,
        "Foo::Error" => false
      )
    end
  end

  describe ".missing_settings" do
    it "names the settings the reference has no reader for" do
      YARD::Registry.clear
      YARD.parse_string(<<~RUBY)
        module NitroIntelligence
          # Settings.
          class Configuration
            # @!attribute [rw] documented
            #   @return [String] a setting
            config_accessor :documented, :undocumented
          end
        end
      RUBY
      expect(described_class.missing_settings(%i[documented undocumented])).to eq(["undocumented"])
    ensure
      YARD::Registry.clear
    end
  end
end
