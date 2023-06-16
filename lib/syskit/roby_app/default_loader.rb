# frozen_string_literal: true

module Syskit
    module RobyApp
        # OroGen loader that handles type and orogen model export to Types and OroGen
        class DefaultLoader < OroGen::Loaders::Aggregate
            def initialize(app, type_export_namespace: nil)
                @app = app
                @type_export_namespace = type_export_namespace
                # We need recursive access lock
                @load_access_lock = Monitor.new

                super()

                return unless type_export_namespace

                registry.export_to_ruby(type_export_namespace) do |type, exported_type|
                    resolve_ruby_type(type, exported_type)
                end
            end

            def register_typekit_model(typekit)
                super

                return if typekit.virtual?
                return if Syskit.conf.only_load_models?

                Runkit.load_typekit(typekit.name)
            end

            # @api private
            #
            # Resolve the type that should be stored in the Types... hierarchy
            def resolve_ruby_type(type, exported_type)
                if type.name =~ /orogen_typekits/
                    # just ignore those
                elsif type <= Typelib::NumericType
                    # using numeric is transparent in Typelib/Ruby
                elsif type.contains_opaques?
                    # register the intermediate instead
                    intermediate_type_for(type)
                elsif m_type?(type)
                    # just ignore, they are registered as the opaque
                else
                    exported_type
                end
            end

            def clear
                super

                @type_export_namespace&.reset_registry_export(registry)

                nil
            end

            def task_model_from_name(name)
                @load_access_lock.synchronize do
                    super
                end
            end
        end
    end
end
