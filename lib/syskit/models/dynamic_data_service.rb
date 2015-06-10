module Syskit
    module Models
        # Representation of a dynamic service registered with
        # Component#dynamic_service
        class DynamicDataService
            # The component model we are bound to
            attr_reader :component_model
            # The dynamic service name
            attr_reader :name
            # The service model
            attr_reader :service_model
            # The service definition block
            attr_reader :block

            def initialize(component_model, name, service_model, block)
                @component_model, @name, @service_model, @block = component_model, name, service_model, block
            end

            def attach(component_model)
                result = dup
                result.instance_variable_set(:@component_model, component_model)
                result
            end

            # Intermediate object used to evaluate the blocks given to
            # Component#dynamic_service
            class InstantiationContext
                # The component model in which this service is being
                # instantiated
                attr_reader :component_model
                # The name of the service that is being instantiated
                attr_reader :name
                # The dynamic service description
                attr_reader :dynamic_service
                # The instantiated service
                attr_reader :service
                # A set of options that are accessible from the instanciation
                # block. This allows to create protocols for dynamic service
                # creation, and is specific to the client component model
                # @return [Hash]
                attr_reader :options

                def initialize(component_model, name, dynamic_service, options = Hash.new)
                    @component_model, @name, @dynamic_service, @options =
                        component_model, name, dynamic_service, options
                end

                # Proxy to declare a new argument on the (specialized) component
                # model
                def argument(name, options = Hash.new)
                    component_model.argument(name, options)
                end

                # Proxy for component_model#provides which does some sanity
                # checks
                def provides(service_model, port_mappings = Hash.new, as: nil, **arguments)
                    if service
                        raise ArgumentError, "this dynamic service instantiation block already created one new service"
                    end

                    if !service_model.fullfills?(dynamic_service.service_model)
                        raise ArgumentError, "#{service_model.short_name} does not fullfill the model for the dynamic service #{dynamic_service.name}, #{dynamic_service.service_model.short_name}"
                    end

                    if as && as != name
                        raise ArgumentError, "the as: argument was given (with value #{as}) but it is required to be #{name}. Note that it can be omitted in a dynamic service block"
                    end
                    @service = component_model.provides_dynamic(service_model, port_mappings, as: name, **arguments)
                    service.dynamic_service = dynamic_service
                    service.dynamic_service_options = self.options.dup
                    service

                rescue InvalidPortMapping => e
                    raise InvalidProvides.new(component_model, service_model, e), "while instanciating the dynamic service #{dynamic_service}: #{e}", e.backtrace
                end
            end


            def instanciate(name, options = Hash.new)
                instantiator = InstantiationContext.new(component_model, name, self, options)
                instantiator.instance_eval(&block)
                if !instantiator.service
                    raise InvalidDynamicServiceBlock.new(self), "the block #{block} used to instantiate the dynamic service #{name} on #{component_model.short_name} with options #{options} did not provide any service"
                end
                instantiator.service
            end

            # Updates the component_model's oroGen interface description to
            # include the ports needed for the given dynamic service model
            #
            # @return [Hash{String=>String}] the updated port mappings
            def self.update_component_model_interface(component_model, service_model, user_port_mappings)
                port_mappings = Hash.new
                service_model.each_output_port do |service_port|
                    port_mappings[service_port.name] = directional_port_mapping(component_model, 'output', service_port, user_port_mappings[service_port.name])
                end
                service_model.each_input_port do |service_port|
                    port_mappings[service_port.name] = directional_port_mapping(component_model, 'input', service_port, user_port_mappings[service_port.name])
                end

                # Unlike #data_service, we need to add the service's interface
                # to our own
                Syskit::Models.merge_orogen_task_context_models(component_model.orogen_model, [service_model.orogen_model], port_mappings)
                port_mappings
            end

            # Validates the setup for a single data service port, and
            # computes the port mapping for it. It validates the port
            # creation rule that a mapping must be given for a port to be
            # created.
            def self.directional_port_mapping(component_model, direction, port, expected_name)
                # Filter out the ports that already exist on the component
                if expected_name
                    if component_model.send("find_#{direction}_port", expected_name)
                        return expected_name
                    end
                else
                    expected_name = component_model.find_directional_port_mapping(direction, port, nil)
                    if !expected_name
                        raise InvalidPortMapping, "no explicit mapping has been given for the service port #{port.name} and no port on #{component_model.short_name} matches. You must give an explicit mapping of the form 'service_port_name' => 'task_port_name' if you expect the port to be dynamically created."
                    end
                    return expected_name
                end

                # Now verify that the rest can be instanciated
                if !component_model.send("has_dynamic_#{direction}_port?", expected_name, port.type)
                    raise InvalidPortMapping, "there are no dynamic #{direction} ports declared in #{component_model.short_name} that match #{expected_name}:#{port.type_name}"
                end
                return expected_name
            end
        end
    end
end

