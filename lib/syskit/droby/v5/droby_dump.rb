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
        end
    end
end

