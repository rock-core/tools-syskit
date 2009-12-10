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
            inherited_enumerable(:main_data_source, :main_data_sources) { Set.new }
            inherited_enumerable(:data_source, :data_sources, :map => true) { Hash.new }

            def self.instanciate(engine, arguments = Hash.new)
                _, task_arguments = Model.filter_instanciation_arguments(arguments)
                engine.plan.add(task = new(task_arguments))
                task
            end

            DATA_SOURCE_ARGUMENTS = { :model => nil, :as => nil, :slave_of => nil }

            def self.data_source(type_name, arguments = Hash.new)
                type_name = type_name.to_str
                source_arguments, arguments = Kernel.filter_options arguments,
                    DATA_SOURCE_ARGUMENTS

                main_data_source = !arguments[:as]

                name = (source_arguments[:as] || type_name).to_str
                model = source_arguments[:model] || Roby.app.orocos_data_sources[type_name]
                if !model
                    raise ArgumentError, "there is no data source called #{type_name}"
                end

                if has_data_source?(name)
                    parent_type = data_source_type(name)
                    if !(model < parent_type)
                        raise SpecError, "#{self} already has a data source named #{name}"
                    end
                end

                include model
                arguments.each do |key, value|
                    send("#{key}=", value)
                end

                if parent_source = source_arguments[:slave_of]
                    if !has_data_source?(parent_source.to_str)
                        raise SpecError, "parent source #{parent_source} is not registered on #{self}"
                    end

                    data_sources["#{parent_source}.#{name}"] = model
                else
                    argument "#{name}_name"
                    data_sources[name] = model
                    if main_data_source
                        main_data_sources << name
                    end
                end
                model
            end


            # Return the selected name for the given data source, or nil if none
            # is selected yet
            def selected_data_source(data_source_name)
                root_source, child_source = model.break_data_source_name(data_source_name)
                if child_source
                    # Get the root name
                    if selected_source = selected_data_source(root_source)
                        return "#{selected_source}.#{child_source}"
                    end
                else
                    arguments["#{root_source}_name"]
                end
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

            def self.method_missing(name, *args)
                if args.empty? && (port = self.port(name))
                    port
                else
                    super
                end
            end

            # Map the given port name of the data source's interface into the
            # actual port of the given component.
            def self.map_port_name(port_name, source_type, source_name)
                if main_data_source?(source_name)
                    if port(port_name)
                        return port_name
                    else
                        raise ArgumentError, "expected #{self} to have a port named #{source_name}"
                    end
                else
                    target_name = "#{source_name}#{port_name.capitalize}"
                    if port(target_name)
                        return target_name
                    else
                        raise ArgumentError, "expected #{self} to have a port named #{target_name}"
                    end
                end
            end
        end

        class Component::TransactionProxy < Roby::Transactions::Task
            proxy_for Component
        end

        Flows = Roby::RelationSpace(Component)
        Flows.apply_on Component::TransactionProxy
        Flows.relation :DataFlow, :child_name => :sink, :parent_name => :source, :dag => false
    end
end

