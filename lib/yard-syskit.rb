module Roby
    module YARD
        include ::YARD

        class OroGenHandler < YARD::Handlers::Ruby::ClassHandler
            def self.handles?(node)
                return if !super
                node.class_name.namespace[0] == "OroGen"
            end

            def parse_superclass(statement)
                # We assume that all classes in OroGen have Syskit::TaskContext
                # as superclass by default
                if !statement
                    statement = ::YARD.parse_string("Syskit::TaskContext").
                        enumerator.first
                end
                super(statement)
            end
        end

        class DataServiceProvidesHandler < ::YARD::Handlers::Ruby::MixinHandler
            handles method_call(:provides)
            namespace_only

            def process
                process_mixin(statement.parameters(false).first)
            end
        end

        class DataServiceBaseDSL < YARD::Handlers::Ruby::Base
            namespace_only

            def process
                name = call_params[0]

                klass = register(ModuleObject.new(namespace, name))
                statement.parameters.each do |p|
                    if p.respond_to?(:type) && p.type == :list
                        p.each do |item|
                            if item.respond_to?(:type) && item.type == :assoc
                                key = item[0].jump(:ident).source
                                if key == 'parent:'
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

        class DataServiceTypeDSL < DataServiceBaseDSL
            handles method_call(:data_service_type)
        end

        class DeviceTypeDSL < DataServiceBaseDSL
            handles method_call(:device_type)
        end

        class ComBusTypeDSL < DataServiceBaseDSL
            handles method_call(:com_bus_type)
        end

        class ProfileDSL < DataServiceBaseDSL
            handles method_call(:profile)
        end
    end
end

