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
                orogen_m = ModuleObject.new(namespace, "::OroGen")
                project_m = ModuleObject.new(orogen_m, call_params[0].camelcase(:upper))
                register project_m
                project_m.docstring.replace("Created by Syskit to represent the #{call_params[0]} oroGen project")
            end
        end

        class OroGenHandler < YARD::Handlers::Ruby::ClassHandler
            handles :class
            namespace_only

            def self.handles?(node)
                return unless super

                node.class_name.namespace[0] == "OroGen"
            end

            def process
                path = statement.class_name.source.split("::")
                orogen_m = ModuleObject.new(namespace, "::OroGen")
                ModuleObject.new(orogen_m, path[1])
                super
            end

            def parse_superclass(statement)
                # We assume that all classes in OroGen have Syskit::TaskContext
                # as superclass by default
                statement ||= ::YARD.parse_string("Syskit::TaskContext")
                                    .enumerator.first
                super(statement)
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
