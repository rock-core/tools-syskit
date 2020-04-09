# frozen_string_literal: true

module Syskit
    # @api private
    #
    # Base implementation of the creation of models that represent an arbitrary
    # mix of a task model and a set of data services.
    #
    # Its most common usage it to represent a single data service (which is seen
    # as a {Component} model with an extra data service). It can also be used to
    # represent a taskcontext model that should have an extra data service at
    # dependency-injection time because of e.g. dynamic service instantiation.
    module Placeholder
        def placeholder?
            true
        end

        def proxied_data_service_models
            model.proxied_data_service_models
        end

        def provided_models
            [model.proxied_component_model, model.proxied_data_service_models]
        end
    end
end
