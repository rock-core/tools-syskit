require 'logger'
require 'utilrb/logger'
require 'orocos/roby/exceptions'
require 'facets/string/snakecase'

module Orocos
    # Roby is a plan management component, i.e. a supervision framework that is
    # based on the concept of plans.
    #
    # See http://doudou.github.com/roby for more information.
    #
    # This module includes both the Roby bindings, i.e. what allows to represent
    # Orocos task contexts and deployment processes in Roby, and a model-based
    # system configuration environment.
    module RobyPlugin
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
        def self.create_orogen_interface(name)
            basename = "roby_#{name.gsub(/[^\w]/, '_')}".camelcase(:upper)
	    begin
		Roby.app.main_orogen_project.find_task_context(basename)
                basename << "_DD"
            rescue ArgumentError
            end

            interface = Roby.app.main_orogen_project.
                external_task_context(basename)
            interface
        end

        # Returns an array of modules. It is used as the search path for DSL
        # parsing.
        #
        # I.e. when someone uses a ClassName in a DSL, this constant will be
        # searched following the order of modules returned by this method.
        def self.constant_search_path
            [Orocos::RobyPlugin]
        end

        # Generic module included in all classes that are used as models.
        #
        # The Roby plugin uses, as Roby does, Ruby classes as model objects. To
        # ease code reading, the model-level functionality (i.e. singleton
        # classes) are stored in separate modules whose name finishes with Model
        #
        # For instance, the singleton methods of Component are defined on
        # ComponentModel, Composition on CompositionModel and so on.
        module Model
            # All models are defined in the context of a SystemModel instance.
            # This is this instance
            attr_accessor :system_model

            # Returns a string suitable to reference an element of type +self+.
            #
            # This is for instance used by the composition if no explicit name
            # is given:
            #
            #   add ElementModel
            #
            # will have a default name of
            #
            #   ElementModel.snakename
            def snakename
                name.gsub(/.*::/, '').snakecase
            end

            # Returns a string suitable to reference +self+ as a constant
            #
            # This is for instance used by SystemModel to determine what name to
            # use to export new models as constants:
            def constant_name
                name.gsub(/.*::/, '').camelcase(:upper)
            end

            def to_s # :nodoc:
                supermodels = ancestors.map(&:name)
                i = supermodels.index("Orocos::RobyPlugin::Component")
                supermodels = supermodels[0, i]
                supermodels = supermodels.map do |name|
                    name.gsub(/Orocos::RobyPlugin::(.*)/, "\\1") if name
                end
                "#<#{supermodels.join(" < ")}>"
            end

            # Creates a new class that is a submodel of this model
            def new_submodel
                klass = Class.new(self)
                klass.system_model = system_model
                klass
            end

            def self.validate_service_model(model, system_model, expected_type = DataService)
                if !model.kind_of?(DataServiceModel)
                    raise ArgumentError, "expected a data service, source or combus model, got #{model} of type #{model.class}"
                elsif !(model < expected_type)
                    # Try harder. This is meant for DSL loading, as we define
                    # data services for data sources and so on
                    if query_method = SystemModel::MODEL_QUERY_METHODS[expected_type]
                        model = system_model.send(query_method, model.name)
                    end
                    if !model
                        raise ArgumentError, "expected a submodel of #{expected_type.short_name} but got #{model} of type #{model.class}"
                    end
                end
                model
            end

            def self.validate_model_name(name)
                if !name.respond_to?(:to_str)
                    raise ArgumentError, "expected a string as a model name, got #{name}"
                elsif !(name.camelcase(:upper) == name)
                    raise ArgumentError, "#{name} is not a valid model name. Model names must start with an uppercase letter, and are usually written in UpperCamelCase"
                end
                name
            end

            # Helper for #instance calls on components
            def self.filter_instanciation_arguments(options)
                arguments, task_arguments = Kernel.filter_options(
                    options, :selection => Hash.new, :as => nil)
            end

            def short_name
                name.gsub('Orocos::RobyPlugin::', '')
            end
        end

        # For 1.8 compatibility
        if !defined?(BasicObject)
            BasicObject = Object
        end

        # Instances of Project are the namespaces into which the other
        # orocos-related objects (Deployment and TaskContext) are defined.
        #
        # For instance, the TaskContext sublass that represnets an imu::Driver
        # task context will be registered as Orocos::RobyPlugin::Imu::Driver
        class Project < Module
            # The instance of Orocos::Generation::TaskLibrary that contains the
            # specification information for this orogen project.
            attr_reader :orogen_spec
        end

        # Returns the Project instance that represents the given orogen project.
        def self.orogen_project_module(name)
            const_name = name.camelcase(:upper)
            Orocos::RobyPlugin.define_or_reuse(const_name) do
                mod = Project.new
                mod.instance_variable_set :@orogen_spec, ::Roby.app.loaded_orogen_projects[name]
                mod
            end
        end

    end
end

