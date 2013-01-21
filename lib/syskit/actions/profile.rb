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
                super()
            end

            # Add some dependency injections for the definitions in this profile
            def use(*args)
                add(*args)
                self
            end

            # Give a name to a known instance requirement object
            def define(name, requirements)
                requirements = requirements.to_instance_requirements
                requirements.dependency_injection_context.push(self)
                definitions[name] = requirements
            end

            def initialize_copy(old)
                super
                old.definitions.each do |name, req|
                    definitions[name] = req.dup
                end
            end
            # Clears this profile of all data, leaving it blank
            #
            # This is mostly used in Roby's model-reloading procedures
            def clear_model
                @robot = Robot::RobotDefinition.new
                definitions.clear
                @dependency_injection = DependencyInjection.new
                used_profiles.clear
            end
        end
    end
end


