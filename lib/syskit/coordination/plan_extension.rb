# frozen_string_literal: true

module Syskit
    module Coordination
        module PlanExtension
            # Representation of a data monitoring table attached to a plan
            #
            # @!attribute [rw] model
            #   The data monitoring table model
            #   @return [Models::DataMonitoringTable]
            #
            # @!attribute [rw] arguments
            #   The arguments that should be used to create the table instance
            #   @return [Hash<Symbol,Object>]
            #
            # @!attribute [rw] triggers
            #   The triggers that would activate the table, as returned by
            #   {Roby::Plan#add_trigger}
            #   @return [Roby::Plan::Trigger]
            #
            # @!attribute [rw] instances
            #   The set of table instances created so far
            #   @return [Hash<Roby::Task,DataMonitoringTable>]
            AttachedDataMonitoringTable = Struct.new :model, :arguments, :triggers, :instances

            # Set of data monitoring tables attached to this plan
            #
            # @return [Set<AttachedDataMonitoringTable>]
            attribute(:data_monitoring_tables) { Set.new }

            # Activates the given {DataMonitoringTable} model on this plan
            #
            # Instances of this table model will be attached to all tasks that
            # match one of the table's attachment points (see
            # {Models::DataMonitoringTable#attach_to}). If no attachment points
            # have been given, every tasks matching the table's root model will
            # be selected
            #
            # @param [Model<DataMonitoringTable>] table_m the table model
            # @param [Hash] arguments the arguments that should be passed to the
            #   data monitoring tables
            # @return [Object] an ID that can be used as an argument to
            #   {#remove_data_monitoring_table}
            def use_data_monitoring_table(table_m, arguments = {})
                # Verify that all required arguments are set, and that all
                # arguments are known
                arguments = table_m.validate_arguments(arguments)

                queries = table_m.each_attachment_point.to_a
                if queries.empty?
                    queries << table_m.task_model.query.not_abstract
                end

                table_record = AttachedDataMonitoringTable.new table_m, arguments, Set.new, {}
                queries.each do |query|
                    trigger = add_trigger(query) do |task|
                        unless table_record.instances.key?(task)
                            task.when_finalized do |t|
                                table_record.instances.delete(task)
                            end
                            table_record.instances[task] = table_m.new(task, arguments)
                        end
                    end
                    table_record.triggers << trigger
                end
                data_monitoring_tables << table_record
                table_record
            end

            # Removes a data monitoring table from this plan
            #
            # @param [Object] table the value returned by
            #   {#use_data_monitoring_table}
            # @return [void]
            def remove_data_monitoring_table(table)
                if data_monitoring_tables.delete(table)
                    table.triggers.each do |tr|
                        remove_trigger(tr)
                    end
                    table.instances.each do |task, tbl|
                        tbl.remove!
                    end
                end
                nil
            end
        end
    end
end

Roby::Plan.include Syskit::Coordination::PlanExtension
