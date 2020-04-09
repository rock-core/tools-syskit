# frozen_string_literal: true

module Syskit
    module Coordination
        module Models
            module TaskExtension
                # Returns the data monitoring table that should be added to all
                # instances of this task
                def data_monitoring_table
                    @data_monitoring_table ||= Syskit::Coordination::DataMonitoringTable.new_submodel(:root => model)
                end

                # Mapping from data monitoring arguments to coordination context variables
                def data_monitoring_arguments
                    @data_monitoring_arguments ||= {}
                end

                # Add a data monitor on this particular coordination task
                #
                # It will be added to all the instances of this task
                def monitor(name, *data_streams)
                    if data_streams.last.kind_of?(Hash)
                        options = Kernel.normalize_options data_streams.pop
                        options.each do |key, value|
                            if key.respond_to?(:to_sym) && value.kind_of?(Roby::Coordination::Models::Variable)
                                data_monitoring_arguments[value.name] = key
                                data_monitoring_table.argument key
                            end
                        end
                    end

                    data_monitoring_table.monitor(name, *data_streams)
                end

                def setup_instanciated_task(coordination_context, task, arguments = {})
                    table_arguments = {}
                    arguments.each do |key, value|
                        if var = data_monitoring_arguments[key]
                            table_arguments[var] = value
                        end
                    end
                    data_monitoring_table.new(
                        task, table_arguments,
                        on_replace: :copy,
                        parent: coordination_context
                    )
                    super
                end
            end
        end
    end
end
Roby::Coordination::Models::TaskWithDependencies.class_eval do
    prepend Syskit::Coordination::Models::TaskExtension
end
