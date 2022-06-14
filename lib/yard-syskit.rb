# frozen_string_literal: true

require "facets/string/camelcase"

YARD::Templates::Engine.register_template_path(
    File.expand_path(
        File.join(__dir__, "syskit", "doc", "yard", "templates")
    )
)

module Syskit
    module YARD
        include ::YARD

        def self.syskit_doc_output_path
            unless @syskit_doc_output_path
                if (env = ENV["SYSKIT_DOC_OUTPUT_PATH"])
                    @syskit_doc_output_path = Pathname.new(env)
                end
            end

            @syskit_doc_output_path
        end

        def self.load_metadata_for(name)
            return unless (root_path = syskit_doc_output_path)

            path = name.split("::").inject(root_path, &:/).sub_ext(".yml")
            unless path.exist?
                puts "no data in #{path} for #{name}"
                return
            end

            Metadata.load path
        end

        class ComponentHandler < ::YARD::Handlers::Ruby::Base
            handles :class
            in_file %r{models/compositions/.*\.rb$}

            COMPONENT_CLASSES = %w[
                Syskit::Composition
            ].freeze

            def process
                classname = statement[0].source.gsub(/\s/, "")
                klass = ::YARD::CodeObjects::ClassObject.new(namespace, classname)
                klass[:syskit] = YARD.load_metadata_for(klass.path)
                klass
            end
        end

        class SyskitExtendModelHandler < ::YARD::Handlers::Ruby::Base
            handles method_call(:extend_model)

            def process
                name = statement.parameters.source
                return unless (name_match = /^OroGen\.(\w+)\.(\w+)$/.match(name))

                _, tasks = YARD.define_orogen_project(name_match[1])
                return unless (task_m = tasks[name_match[2]])

                if (block = statement.block)
                    parse_block(block.children.first, namespace: task_m)
                end
            end
        end

        class DataServiceProvidesHandler < ::YARD::Handlers::Ruby::MixinHandler
            handles method_call(:provides)
            namespace_only

            def process
                provided_model = statement.parameters(false).first
                # Model may be external, in which case YARD does not know it's a module
                process_mixin(provided_model) if provided_model.respond_to?(:mixins)
            end
        end

        class DSLBaseHandler < YARD::Handlers::Ruby::Base
            namespace_only

            def process
                name = call_params[0]

                klass = register(ModuleObject.new(namespace, name))
                statement.parameters.each do |p|
                    if p.respond_to?(:type) && p.type == :list
                        p.each do |item|
                            if item.respond_to?(:type) && item.type == :assoc
                                key = item[0].jump(:ident).source
                                if key == "parent:"
                                    case obj = Proxy.new(namespace, item[1].source)
                                    when ConstantObject # If a constant is included, use its value as the real object
                                        obj = Proxy.new(namespace, obj.value, :module)
                                    else
                                        obj = Proxy.new(namespace, item[1].source, :module)
                                    end

                                    klass.mixins(scope).unshift(obj) unless klass.mixins(scope).include?(obj)
                                end
                            end
                        end
                    end
                end

                if (block = statement.block)
                    parse_block(block.children.first, namespace: klass)
                end

                klass[:syskit] = YARD.load_metadata_for(klass.path)
                klass
            end
        end

        class DataServiceTypeDSL < DSLBaseHandler
            handles method_call(:data_service_type)
        end

        class DeviceTypeDSL < DSLBaseHandler
            handles method_call(:device_type)
        end

        class ComBusTypeDSL < DSLBaseHandler
            handles method_call(:com_bus_type)
        end

        class ProfileDSL < DSLBaseHandler
            handles method_call(:profile)
        end

        class UsingTaskLibrary < YARD::Handlers::Ruby::Base
            handles method_call(:using_task_library)

            def process
                YARD.define_orogen_project(call_params[0])
            end
        end

        PORT_DIRECTION_TO_CLASS = {
            "in" => "InputPort",
            "out" => "OutputPort"
        }.freeze

        def self.define_orogen_project(project_name)
            orogen_m = ::YARD::CodeObjects::ModuleObject.new(:root, "::OroGen")
            project_m = ::YARD::CodeObjects::ModuleObject.new(orogen_m, project_name)
            project_m.docstring.replace(
                "Created by Syskit to represent the #{project_name} oroGen project"
            )

            return unless (root_path = YARD.syskit_doc_output_path)

            project_path = root_path / "OroGen" / project_name
            tasks = project_path.glob("*.yml").each_with_object({}) do |task_yml, h|
                task_name = task_yml.sub_ext("").basename.to_s
                h[task_name] = define_task_context_model(project_m, task_name)
            end

            [project_m, tasks]
        end

        def self.define_task_context_model(project_m, task_name)
            task_m = ::YARD::CodeObjects::ClassObject.new(project_m, task_name)
            task_m.superclass = "Syskit::TaskContext"
            task_m[:syskit] = YARD.load_metadata_for(task_m.path)

            define_task_context_model_ports(task_m)
            define_task_context_model_services(task_m)

            task_m
        end

        def self.define_task_context_model_services(task_m)
            task_m[:syskit].bound_services&.each do |desc|
                method_name = "#{desc['name']}_srv"

                method = ::YARD::CodeObjects::MethodObject.new(task_m, method_name)
                method.docstring.replace(<<~DESC)
                    #{desc['doc']}

                    @return [Syskit::BoundDataService<#{desc['model']}>]
                DESC

                method = CodeObjects::MethodObject.new(task_m, method_name, :class)
                method.docstring.replace(<<~DESC)
                    #{desc['doc']}

                    @return [Syskit::Models::BoundDataService<#{desc['model']}>]
                DESC
            end
        end

        def self.define_task_context_model_ports(task_m)
            task_m[:syskit].ports&.each do |port_description|
                port_t = PORT_DIRECTION_TO_CLASS.fetch(port_description["direction"])

                method_name = "#{port_description['name']}_port"

                method = ::YARD::CodeObjects::MethodObject.new(task_m, method_name)
                method.docstring.replace(<<~DESC)
                    #{port_description['doc']}

                    @return [Syskit::#{port_t}<#{port_description['type']}>]
                DESC

                method = CodeObjects::MethodObject.new(task_m, method_name, :class)
                method.docstring.replace(<<~DESC)
                    #{port_description['doc']}

                    @return [Syskit::Models::#{port_t}<#{port_description['type']}>]
                DESC
            end
        end

        # @api private
        #
        # Loading and manipulation of the data generated by `syskit doc`
        class Metadata
            def initialize(data)
                @data = data
            end

            def provided_services
                @data["provided_services"]
            end

            def bound_services
                @data["bound_services"]
            end

            def ports
                @data["ports"]
            end

            def hierarchy_graph_path
                @data.dig("graphs", "hierarchy")
            end

            def dataflow_graph_path
                @data.dig("graphs", "dataflow")
            end

            def interface_graph_path
                @data.dig("graphs", "interface")
            end

            # Load data from a file
            #
            # @param [Pathname] path
            # @return Metadata
            def self.load(path)
                new YAML.safe_load(path.read)
            end
        end
    end
end
