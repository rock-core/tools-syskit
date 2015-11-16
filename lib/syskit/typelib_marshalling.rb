module Syskit
    module TypelibMarshalling
        # @return [Typelib::Registry] the registry used for
        #   marshalling/demarshalling. Usually Orocos.registry.
        def self.reference_registry
            Orocos.registry
        end

        # Module used to allow droby-marshalling of Typelib values
        #
        # The manipulated registry is Orocos.registry
        module TypeExtension
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
                DRoby.new(to_byte_array, Roby::Distributed.format(self.class, peer))
            end
        end

        # Module used to allow droby-marshalling of Typelib types
        #
        # The manipulated registry is {TypelibMarshalling.reference_registry}
        module TypeModelExtension
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
                        TypelibMarshalling.reference_registry.merge(reg)
                    end
                    TypelibMarshalling.reference_registry.get(name)
                end
            end

            def droby_dump(peer)
                if !peer || !peer.registry.include?(name)
                    reg = registry.minimal(name)
                    xml = reg.to_xml

                    if peer
                        peer.registry.merge(reg)
                    end
                end
                DRoby.new(name, xml)
            end
        end

        # Extension for all peer-compatible classes. It allows to store which
        # type representations have already been sent, removing the need to send
        # them again
        module DRobyPeerExtension
            # A typelib registry that contains the definition of all types sent to 
            attribute(:registry) { Typelib::Registry.new }
        end

        Typelib::Type.include TypeExtension
        Typelib::Type.extend TypeModelExtension
        Roby::Distributed::RemoteObjectManager.include DRobyPeerExtension
        Roby::Distributed::DumbManager.extend DRobyPeerExtension
        Roby::Log.extend DRobyPeerExtension
    end
end

