# frozen_string_literal: true

require "metaruby/gui/html/page"
require "syskit/gui/page_extension"
module Syskit
    module GUI
        class HTMLPage < MetaRuby::GUI::HTML::Page
            include PageExtension
        end
    end
end
