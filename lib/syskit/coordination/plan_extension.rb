module Syskit
    module Coordination
        module PlanExtension
            attribute(:data_monitoring_tables) { Hash.new }

            # Activates the given {DataMonitoringTable} model on this plan
            #
            # Instances of this table model will be attached to all tasks that
            # match one of the table's attachment points (see
            # {Models::DataMonitoringTable#attach_to}). If no attachment points
            # have been given, every tasks matching the table's root model will
            # be selected
            def use_data_monitoring_table(table_m, arguments = Hash.new)
                # Verify that all required arguments are set, and that all
                # arguments are known
                arguments = table_m.validate_arguments(arguments)

                queries = table_m.each_attachment_point.to_a
                if queries.empty?
                    queries << table_m.task_model.match.not_abstract
                end
                data_monitoring_tables[table_m] = []
                queries.each do |query|
                    add_trigger(query) do |task|
                        if tasks = data_monitoring_tables[table_m]
                            if !tasks.include?(task)
                                tasks << task
                                table_m.new(task, arguments)
                            end
                        end
                    end
                end
            end

            def finalized_task(task)
                super if defined? super

                data_monitoring_tables.each do |tlb, tasks|
                    tasks.delete(task)
                end
            end
        end
    end
end

Roby::Plan.include Syskit::Coordination::PlanExtension
