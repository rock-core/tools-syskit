require 'logger'
require 'utilrb/logger'
require 'utilrb/hash/map_value'
require 'orocos/roby/exceptions'
require 'facets/string/snakecase'

class Object
    def short_name
        to_s
    end
end

module Syskit
    extend Logger::Root('Syskit', Logger::WARN)

    # For 1.8 compatibility
    if !defined?(BasicObject)
        BasicObject = Object
    end
end

