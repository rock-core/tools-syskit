# frozen_string_literal: true

SimpleCov.command_name "syskit"
SimpleCov.start do
    add_filter "^/test/"
    add_filter "/gui/"
    add_filter "/scripts/"
end
