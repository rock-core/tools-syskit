# frozen_string_literal: true

require "metaruby/gui/model_browser"
require "syskit/gui/page_extension"
module Syskit
    module GUI
        class Page < MetaRuby::GUI::ModelBrowser::Page
            include PageExtension
        end
    end
end
