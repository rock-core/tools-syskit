module Syskit
    module Models
        # Representation of instanciated dynamic services
        class BoundDynamicDataService < BoundDataService
            # The dynamic service that has been used to create this
            # particular service
            attr_accessor :dynamic_service
            # The options used during the service instanciation
            attr_accessor :dynamic_service_options

            # Whether this service can be added dynamically (i.e.  without
            # requiring a reconfigure)
            def dynamic?
                dynamic_service.dynamic?
            end

            # Whether this service must be removed when unused
            def remove_when_unused?
                dynamic_service.remove_when_unused?
            end
        end
    end
end


