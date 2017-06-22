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
                            message_type = Roby.app.default_loader.resolve_type(self.message_type, define_dummy_type: true)
                        else
                            message_type = peer.local_object(self.message_type)
                        end
                        
                        # We unfortunately must register the type on the global
                        # loader. We're not ready yet for a fully mixed-loader
                        # setup
                        Roby.app.default_loader.register_type_model(message_type)

                        local_model = supermodel.new_submodel(name: name, lazy_dispatch: lazy_dispatch, message_type: message_type)
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

            module ProfileDumper
                class DRoby
                    def initialize(name)
                        @name = name
                    end

                    def proxy(peer)
                        if !@name
                            return Actions::Profile.new
                        elsif local = peer.object_manager.find_model_by_name(@name)
                            return local
                        end

                        profile = 
                            begin
                                constant(@name)
                            rescue Exception
                                Actions::Profile.new(@name)
                            end

                        peer.register_model(profile)
                        profile
                    end
                end

                def droby_dump(peer)
                    DRoby.new(name)
                end
            end
        end
    end
end

