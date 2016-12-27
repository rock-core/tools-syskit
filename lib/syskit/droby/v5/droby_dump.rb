module Syskit
    module DRoby
        module V5
            module ComBusDumper
                # Must include this, Roby uses it to know which models can be
                # dumped and which not
                include Roby::DRoby::V5::ModelDumper
                
                class DRoby < Roby::DRoby::V5::DRobyModel
                    attr_reader :message_type
                    attr_reader :lazy_dispatch

                    def initialize(message_type, lazy_dispatch, *args)
                        @message_type = message_type
                        @lazy_dispatch = lazy_dispatch
                        super(*args)
                    end

                    def create_new_proxy_model(peer)
                        supermodel = peer.local_model(self.supermodel)
                        # 2016-05: workaround broken log files in which types
                        #          are marshalled as strings instead of type
                        #          objects
                        if message_type.respond_to?(:to_str)
                            Roby.app.default_loader.resolve_type(message_type, define_dummy_type: true)
                        end
                        
                        local_model = supermodel.new_submodel(name: name, lazy_dispatch: lazy_dispatch, message_type: peer.local_object(message_type))
                        peer.register_model(local_model, remote_siblings)
                        local_model
                    end
                end

                def droby_dump(peer)
                    DRoby.new(
                        peer.dump(message_type),
                        lazy_dispatch?,
                        name,
                        peer.known_siblings_for(self),
                        Roby::DRoby::V5::DRobyModel.dump_supermodel(peer, self),
                        Roby::DRoby::V5::DRobyModel.dump_provided_models_of(peer, self))
                end
            end

            # Module used to allow droby-marshalling of Typelib values
            #
            # The manipulated registry is Orocos.registry
            module TypelibTypeDumper
                # Marshalling representation of a typelib value
                class DRoby
                    attr_reader :byte_array
                    attr_reader :type
                    def initialize(byte_array, type)
                        @byte_array, @type = byte_array, type
                    end
                    def proxy(peer)
                        peer.local_object(type).from_buffer(byte_array)
                    end
                end

                def droby_dump(peer)
                    DRoby.new(to_byte_array, peer.dump(self.class))
                end
            end

            module ObjectManagerExtension
                attribute(:typelib_registry) { Typelib::Registry.new }
            end

            # Module used to allow droby-marshalling of Typelib types
            module TypelibTypeModelDumper
                # Class used to transfer the definition of a type
                class DRoby
                    attr_reader :name, :xml
                    def initialize(name, xml)
                        @name = name
                        @xml = xml
                    end
                    def proxy(peer)
                        if xml
                            reg = Typelib::Registry.from_xml(xml)
                            peer.object_manager.typelib_registry.merge(reg)
                        end
                        peer.object_manager.typelib_registry.get(name)
                    end
                end

                def droby_dump(peer)
                    peer_registry = peer.object_manager.typelib_registry
                    if !peer_registry.include?(name)
                        reg = registry.minimal(name)
                        xml = reg.to_xml
                        peer_registry.merge(reg)
                    end
                    DRoby.new(name, xml)
                end
            end

            # Module used to allow droby-marshalling of InstanceRequirements
            module InstanceRequirementsDumper
                class DRoby
                    attr_reader :base_model
                    attr_reader :abstract
                    attr_reader :arguments
                    attr_reader :selections
                    attr_reader :pushed_selections
                    attr_reader :context_selections
                    attr_reader :deployment_hints
                    attr_reader :specialization_hints
                    attr_reader :dynamics
                    attr_reader :can_use_template

                    def initialize(base_model, abstract, arguments, selections, pushed_selections, context_selections, deployment_hints, specialization_hints, dynamics, can_use_template)
                        @base_model           = base_model
                        @abstract             = abstract
                        @arguments            = arguments
                        @selections           = selections
                        @pushed_selections    = pushed_selections
                        @context_selections   = context_selections
                        @deployment_hints     = deployment_hints
                        @specialization_hints = specialization_hints
                        @dynamics             = dynamics
                        @can_use_template     = can_use_template
                    end

                    def proxy(peer)
                        result = InstanceRequirements.new([peer.local_object(base_model)])
                        result.abstract if abstract
                        result.with_arguments(peer.local_object(arguments))
                        if result.composition_model?
                            result.use(peer.local_object(pushed_selections))
                            result.push_selections
                            result.use(peer.local_object(selections))
                        end
                        result.push_dependency_injection(peer.local_object(context_selections))
                        result.prefer_deployed_tasks(deployment_hints)
                        result.dynamics.merge(dynamics)
                        specialization_hints.each { |hint| result.prefer_specializations(hint) }
                        result.can_use_template = can_use_template
                        result
                    end
                end

                def droby_dump(peer)
                    DRoby.new(
                        peer.dump(base_model),
                        abstract?,
                        peer.dump(arguments),
                        peer.dump(selections),
                        peer.dump(pushed_selections),
                        peer.dump(context_selections),
                        deployment_hints,
                        peer.dump(specialization_hints),
                        dynamics,
                        can_use_template?)
                end
            end
        end
    end
end

class Orocos::RubyTasks::TaskContext
    extend Roby::DRoby::V5::DRobyConstant::Dump
end

class Orocos::TaskContext
    extend Roby::DRoby::V5::DRobyConstant::Dump
end

