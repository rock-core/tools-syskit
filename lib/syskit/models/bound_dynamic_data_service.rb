# frozen_string_literal: true

module Syskit
    module Models
        # Representation of instanciated dynamic services
        class BoundDynamicDataService < BoundDataService
            # The dynamic service that has been used to create this
            # particular service
            attr_accessor :dynamic_service
            # The options used during the service instanciation
            attr_accessor :dynamic_service_options

            def dynamic?
                true
            end

            # Whether this service can be added dynamically (i.e.  without
            # requiring a reconfigure)
            def addition_requires_reconfiguration?
                dynamic_service.addition_requires_reconfiguration?
            end

            # Whether this service must be removed when unused
            def remove_when_unused?
                dynamic_service.remove_when_unused?
            end

            # (see BoundDataService#same_service?)
            def same_service?(other)
                if other.kind_of?(BoundDynamicDataService)
                    (dynamic_service.demoted == other.dynamic_service.demoted) &&
                        (dynamic_service_options == other.dynamic_service_options)
                end
            end
        end
    end
end
