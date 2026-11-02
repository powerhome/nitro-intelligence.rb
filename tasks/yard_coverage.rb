# The documentation check behind `rake yard`.
module YardCoverage
  # YARD documents a reader, writer, constructor or predicate that has no comment itself: an
  # attribute gets a sentence, the others a `@return` tag. Those are not the author's, so an object
  # counts as documented only when its comment, or the directive declaring it, has text of its own.
  def self.undocumented?(object)
    raw = object.docstring.all.strip
    name = object.name.to_s.delete_suffix("=")
    raw.empty? || [
      "Returns the value of attribute #{name}.",
      "Sets the attribute #{name}\n@param value the value to set the attribute #{name} to.",
    ].include?(raw)
  end
end
