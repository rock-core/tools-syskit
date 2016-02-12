module Syskit
    module TypelibMarshalling
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
                DRoby.new(to_byte_array, peer.dump(self.class))
            end
        end

        # Module used to allow droby-marshalling of Typelib types
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

        # Extension for all peer-compatible classes. It allows to store which
        # type representations have already been sent, removing the need to send
        # them again
        module DRobyObjectManagerExtension
            # A typelib registry that contains the definition of all types sent to 
            attribute(:registry) { Typelib::Registry.new }
        end

        Typelib::Type.include TypeExtension
        Typelib::Type.extend  TypeModelExtension
        Roby::DRoby::ObjectManager.include DRobyObjectManagerExtension
    end
end

