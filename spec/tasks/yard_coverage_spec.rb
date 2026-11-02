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
end
