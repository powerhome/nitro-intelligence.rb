require "json"

module NitroIntelligence
  # Incremental parser for the event stream returned by the Assistants API. Net::HTTP can split
  # anywhere -- including in the middle of a line or a multi-byte token -- so callers feed this
  # raw response chunks and receive one event only after its blank-line terminator arrives.
  class ServerSentEventParser
    def initialize(&on_event)
      @buffer = +""
      @on_event = on_event
    end

    def <<(chunk)
      @buffer << chunk
      consume_events
      self
    end

    def finish
      consume_event(@buffer) if @buffer.present?
      @buffer.clear
    end

  private

    def consume_events
      while (boundary = @buffer.match(/\r?\n\r?\n/))
        raw_event = @buffer.slice!(0, boundary.end(0))
        consume_event(raw_event)
      end
    end

    def consume_event(raw_event)
      fields = raw_event.lines(chomp: true).each_with_object({ "data" => [] }) do |line, event|
        next if line.blank? || line.start_with?(":")

        field, value = line.split(":", 2)
        value = value.to_s.delete_prefix(" ")
        field == "data" ? event["data"] << value : event[field] = value
      end
      return if fields["data"].empty? && fields.except("data").empty?

      fields["data"] = parse_data(fields["data"].join("\n"))
      @on_event.call(fields)
    end

    def parse_data(data)
      return if data.blank?

      JSON.parse(data)
    rescue JSON::ParserError
      data
    end
  end
end
