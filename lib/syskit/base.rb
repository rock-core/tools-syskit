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

module Roby
        extend Logger::Forward
        extend Logger::Hierarchy

        # Merge the given orogen interfaces into one subclass
        def self.merge_orogen_interfaces(target, interfaces, port_mappings = Hash.new)
            interfaces.each do |i|
                target.implements i.name
                target.merge_ports_from(i, port_mappings)

                i.each_event_port do |port|
                    target_name = port_mappings[port.name] || port.name
                    target.port_driven target_name
                end
            end
        end

        # Creates a blank orogen interface and returns it
        def self.create_orogen_interface(name = nil, &block)
            Orocos.create_orogen_interface(name, &block)
        end

        # Returns an array of modules. It is used as the search path for DSL
        # parsing.
        #
        # I.e. when someone uses a ClassName in a DSL, this constant will be
        # searched following the order of modules returned by this method.
        def self.constant_search_path
            [Syskit]
        end

        # For 1.8 compatibility
        if !defined?(BasicObject)
            BasicObject = Object
        end

        # Instances of Project are the namespaces into which the other
        # orocos-related objects (Deployment and TaskContext) are defined.
        #
        # For instance, the TaskContext sublass that represnets an imu::Driver
        # task context will be registered as Syskit::Imu::Driver
        class Project < Module
            # The instance of Orocos::Generation::TaskLibrary that contains the
            # specification information for this orogen project.
            attr_reader :orogen_spec
        end

        # Returns the Project instance that represents the given orogen project.
        def self.orogen_project_module(name)
            const_name = name.camelcase(:upper)
            Syskit.define_or_reuse(const_name) do
                mod = Project.new
                mod.instance_variable_set :@orogen_spec, ::Roby.app.loaded_orogen_projects[name]
                mod
            end
        end
end

