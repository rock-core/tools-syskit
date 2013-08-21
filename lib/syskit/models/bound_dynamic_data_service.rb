module Syskit
    module Models
        # Representation of instanciated dynamic services
        class BoundDynamicDataService < BoundDataService
            # The dynamic service that has been used to create this
            # particular service
            attr_accessor :dynamic_service
            # The options used during the service instanciation
            attr_accessor :dynamic_service_options
        end
    end
end


