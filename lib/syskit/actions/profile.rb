module Syskit
    module Actions
        # A representation of a set of dependency injections and definition of
        # pre-instanciated models
        class Profile < DependencyInjection
            # The profile name
            # @return [String]
            attr_reader :name
            # The definitions
            # @return [Hash<String,InstanceRequirements>]
            attr_reader :definitions
            
            def initialize(name)
                @name = name
                @definitions = Hash.new
            end

            # Add some dependency injections for the definitions in this profile
            def use(*args)
                add(*args)
                self
            end

            # Give a name to a known instance requirement object
            def define(name, requirements)
                requirements = requirements.to_instance_requirements
                definitions[name] = requirements
            end

            def initialize_copy(old)
                super
                old.definitions.each do |name, req|
                    definitions[name] = req.dup
                end
            end
        end
    end
end


