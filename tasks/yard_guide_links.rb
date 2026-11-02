# The guides link to one another by file name, as GitHub and MkDocs resolve them, but YARD
# publishes each one as `file.NAME.html`. This points those links at YARD's pages. Their anchors are
# dropped, since YARD names headings differently from GitHub and depends on the Markdown library.
module YardGuideLinks
  GUIDES = Dir[File.expand_path("../docs/*.md", __dir__)].map { |path| File.basename(path, ".md") }.freeze

  def htmlify(text, markup = options.markup)
    super.gsub(/href="(#{Regexp.union(GUIDES)})\.md(?:#[^"]*)?"/) { %(href="file.#{Regexp.last_match(1)}.html") }
  end
end

YARD::Templates::Helpers::HtmlHelper.prepend(YardGuideLinks)
