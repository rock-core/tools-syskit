# frozen_string_literal: true

require "facets/string/camelcase"
module Syskit
    module YARD
        include ::YARD

        class DataServiceProvidesHandler < ::YARD::Handlers::Ruby::MixinHandler
            handles method_call(:provides)
            namespace_only

            def process
                process_mixin(statement.parameters(false).first)
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
    end
end
