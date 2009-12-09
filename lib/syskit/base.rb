module Orocos
    # Roby is a plan management component, i.e. a supervision framework that is
    # based on the concept of plans.
    #
    # This module includes both the Roby bindings, i.e. what allows to represent
    # Orocos task contexts and deployment processes in Roby, and a model-based
    # system configuration environment.
    module RobyPlugin
        class ConfigError < RuntimeError; end
        class SpecError < RuntimeError; end
        class Ambiguous < SpecError; end

        # Generic module included in all classes that are used as models
        module Model
            # The SystemModel instance this model is attached to
            attr_accessor :system

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
                klass.system = system
                klass
            end

            # Helper for #instance calls on components
            def self.filter_instanciation_arguments(options)
                arguments, task_arguments = Kernel.filter_options(
                    options, :selection => Hash.new, :as => nil)
            end
        end

        # Base class for models that represent components (TaskContext,
        # Composition)
        class Component < ::Roby::Task
            inherited_enumerable(:data_source, :data_sources, :map => true) { Hash.new }

            def self.data_source(type_name, arguments = Hash.new)
                type_name = type_name.to_str
                source_arguments, arguments = Kernel.filter_options arguments,
                    :model => nil, :as => type_name, :slave_of => nil

                name = source_arguments[:as].to_str
                if has_data_source?(name)
                    raise SpecError, "#{self} already has a data source named #{name}"
                end

                model = source_arguments[:model] ||
                    DataSourceModel.apply_selection(self, "data source", type_name,
                           Roby.app.orocos_data_sources[type_name], arguments)

                if parent_source = source_arguments[:slave_of]
                    if !has_data_source?(parent_source.to_str)
                        raise SpecError, "parent source #{parent_source} is not registered on #{self}"
                    end

                    data_sources["#{parent_source}.#{name}"] = model
                else
                    argument "#{name}_name"
                    data_sources[name] = model
                end
                model
            end

            # call-seq:
            #   TaskModel.each_root_data_source do |name, source_model|
            #   end
            #
            # Enumerates all sources that are root (i.e. not slave of other
            # sources)
            def self.each_root_data_source(&block)
                each_data_source(nil, false).
                    find_all { |name, source| name !~ /\./ }.
                    each(&block)
            end

            # Returns the type of the given data source, or raises
            # ArgumentError if no such source is declared on this model
            def self.data_source_type(name)
                each_data_source(name) do |type|
                    return type
                end
                raise ArgumentError, "no source #{name} is declared on #{self}"
            end

            def data_source_type(source_name)
                source_name = source_name.to_str
                root_source_name = source_name.gsub /\..*$/, ''
                root_source = model.each_root_data_source.find do |name, source|
                    arguments[:"#{name}_name"] == root_source_name
                end

                if !root_source
                    raise ArgumentError, "there is no source named #{root_source_name}"
                end
                if root_source_name == source_name
                    return root_source.last
                end

                subname = source_name.gsub /^#{root_source_name}\./, ''

                model = self.model.data_source_type("#{root_source.first}.#{subname}")
                if !model
                    raise ArgumentError, "#{subname} is not a slave source of #{root_source_name} (#{root_source.first}) in #{self.model.name}"
                end
                model
            end

            def data_source_name(model_name)
                model_name = model_name.to_str
                root_model_name, subname = model_name.split '.'

                root_model = model.data_source_type(root_model_name)
                root_name  = arguments[:"#{root_model_name}_name"]

                # Validate the subname as well
                if subname
                    model.data_source_type("#{root_model_name}.#{subname}")
                    root_name + ".#{subname}"
                else
                    root_name
                end
            end
        end
    end
end

