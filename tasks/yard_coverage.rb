# The documentation check behind `rake yard`.
module YardCoverage
  # Whether an object lacks documentation of the author's own. YARD's own test counts a docstring
  # with no visible text or tag, such as one holding only `@api public`. YARD also documents a
  # reader, writer, constructor or predicate that has no comment: an attribute or Struct member gets
  # a sentence, the others a `@return` tag. Those are not the author's, so an object counts as
  # documented only when its comment, or the directive declaring it, has text of its own.
  def self.undocumented?(object)
    raw = object.docstring.all.strip
    object.docstring.blank? || raw.empty? || generated?(raw, object.name.to_s.delete_suffix("="))
  end

  # Whether the nearest `@api` tag, on the object or the namespaces around it, is `private`. The
  # reference leaves out a private namespace's page, and with it every member that does not mark
  # itself public, but YARD's statistics still list those members.
  def self.hidden?(object)
    until object.nil? || object.root?
      api = object.tag(:api)
      return api.text == "private" if api

      object = object.namespace
    end
    false
  end

  # The sentences YARD's attribute and Struct handlers write for an undocumented member.
  def self.generated?(raw, name)
    name = Regexp.escape(name)
    reader = /Returns the value of attribute #{name}\.?/
    writer = /Sets the attribute #{name}(?:\n@param value the value to set the attribute #{name} to\.)?/
    raw.match?(/\A(?:#{reader}|#{writer})\z/)
  end

  # The settings among `keys` that the reference has no reader for. `config_accessor` declares
  # them out of YARD's sight, so each needs an `@!attribute` directive to appear at all.
  def self.missing_settings(keys)
    keys.map(&:to_s).reject { |key| YARD::Registry.at("NitroIntelligence::Configuration##{key}") }
  end
end
