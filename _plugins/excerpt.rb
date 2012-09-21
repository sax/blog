# encoding UTF-8
module Jekyll
  module ExcerptFilter
    def extract_excerpt(input)
      input.split('</article>').first.split('<article>').last
    end

    def ellipses(input)
      if input.include?('<article>')
        "..." 
      end
    end
  end
end

Liquid::Template.register_filter(Jekyll::ExcerptFilter)
