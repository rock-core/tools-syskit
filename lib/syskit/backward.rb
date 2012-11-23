module Orocos
    RobyPlugin = Syskit
end

module Syskit
    BoundDataServiceModel = Models::BoundDataService
    ComponentModel = Models::Component
    CompositionModel = Models::Composition
    CompositionSpecializationModel = Models::CompositionSpecialization
    DataService = Models::DataService
    Device = Models::Device
    ComBus = Models::ComBus
    ProvidedDataService = Models::BoundDataService
    DataServiceInstance = BoundDataService
end

# Namespace for all defined composition models
module Compositions; end
# Alias for Compositions
Cmp = Compositions
# Namespace for all defined data service models
module DataServices; end
# Shortcut for DataServices
Srv = DataServices
# Backward compatibility: define the given data service on the Srv module
def data_service_type(*args, &block)
    Srv.data_service_type(*args, &block)
end
# Namespace for all defined device models
module Devices; end
# Shortcut for Devices
Dev = Devices
# Backward compatibility: define the given device type on the Dev module
def device_type(*args, &block)
    Srv.data_service_type(*args, &block)
end

module Orocos
    Cmp = Compositions = ::Compositions
    Dev = Devices = ::Devices
    Srv = DataServices = ::DataServices

    module RobyPlugin
        Cmp = Compositions = ::Compositions
        Dev = Devices = ::Devices
        Srv = DataServices = ::DataServices
    end
end


class Syskit::Engine
    # Load a file that contains both system model and engine
    # requirements
    def load_composite_file(file)
        load file
    end

    # Load the given DSL file into this Engine instance
    def load(file)
        Kernel.load file
    end

    def load_system_model(file)
        Roby.app.load_system_model(file)
    end
end

class Syskit::SystemModel
    # Load the given DSL file into this SystemModel instance
    def load(file)
        relative_path = Roby.app.make_path_relative(file)
        if file != relative_path
            $LOADED_FEATURES << relative_path
        end

        begin
            if Kernel.load_dsl_file(file, self, Syskit.constant_search_path, !Roby.app.filter_backtraces?)
                Syskit.info "loaded #{file}"
            end
        rescue Exception
            $LOADED_FEATURES.delete(relative_path)
            raise
        end

        self
    end
end

# TODO:
#   task_model => proxy_task_model
#   orogen_spec => orogen_model
#   interface => orogen_model
#   create_orogen_interface => create_orogen_task_context_model
#   TaskContext#orogen_name => TaskContext#orocos_name
#
#   create Syskit.create_orogen_deployment_model(:name =>, :task_context_model =>)
#
#   Orocos::TaskContext#input_port, #output_port, #find_input_port,
#   #find_output_port
