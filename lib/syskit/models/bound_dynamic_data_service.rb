module Syskit
    module Models
        # Representation of instanciated dynamic services
        class BoundDynamicDataService < BoundDataService
            # The dynamic service that has been used to create this
            # particular service
            attr_accessor :dynamic_service
        end
    end
end


