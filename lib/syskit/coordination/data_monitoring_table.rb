# frozen_string_literal: true

module Syskit
    module Coordination
        # Definition of a data monitoring table
        #
        # @example Define a data monitoring table that attaches to all tasks of a given type
        #   module Asguard
        #     data_monitoring_table 'TrajectoryFollowing' do
        #       attach_to ControlLoop.specialized_on 'controller' => TrajectoryFollower::Task
        #       monitor('pose', pose_child.pose_samples_port).
        #         trigger_on do |pose|
        #           # Verify that pose is within reasonable bounds of trajectory
        #         end.
        #         raise_exception
        #     end
        #     # Later, in an action interface file
        #     class Main < Roby::Actions::Interface
        #       use_data_monitoring_table Asguard::TrajectoryFollowing
        #     end
        #   end
        #
        # @example Define a standalone monitoring subsystem
        #   module Asguard
        #     class LowLevelMonitor < Syskit::Composition
        #       add BatteryStatusSrv, :as => 'battery_provider'
        #
        #       data_monitoring_table do
        #         monitor('battery_level', battery_provider_child.battery_status_port).
        #           trigger_on do |battery_status|
        #             battery_status.level < Robot.battery_required_to_reach_base
        #           end.
        #           raise_exception
        #       end
        #     end
        #   end
        #   # Later, in a profile definition
        #   define 'low_level_monitor', Asguard::LowLevelMonitor.use(battery_dev)
        #
        # @example Use a data monitoring table in a fault response table
        #   module Asguard
        #     fault_response_table 'Safing' do
        #       use_data_monitoring_table LowLevelMonitor
        #       on_fault battery_level_monitor do
        #         go_recharge
        #       end
        #     end
        #   end
        #
        class DataMonitoringTable < Roby::Coordination::Base
            extend Models::DataMonitoringTable

            # @return [Array<DataMonitor>] list of instanciated data monitors
            attr_reader :monitors

            # (see Roby::Coordination::Base)
            def initialize(root_task, arguments = {}, options = {})
                super(root_task, arguments, options)
                options, = Kernel.filter_options options, :on_replace => :drop
                @poll_id = root_task.poll(options) do
                    poll
                end
                @monitors = []
                @monitors_resolved = false
                resolve_monitors
            end

            # Untie this table from the task it is currently attached to
            #
            # It CANNOT be reused afterwards
            # @return [void]
            def remove!
                root_task.remove_poll_handler(@poll_id)
            end

            # Instanciates all data monitor registered on this table's models
            # and stores the new monitors in {#monitors}
            def resolve_monitors
                model.each_task do |coordination_task_model|
                    if coordination_task_model.respond_to?(:instanciate)
                        root_task.depends_on(task_instance = coordination_task_model.instanciate(root_task.plan))
                        bind_coordination_task_to_instance(
                            instance_for(coordination_task_model), task_instance,
                            on_replace: :copy
                        )
                    end
                end

                monitors_m = model.each_monitor.to_a
                model.validate_monitors(monitors_m)
                root_task.execute do
                    @monitors_resolved = true
                    monitors.concat(monitors_m.map { |m| m.bind(self) })
                end
            end

            # Checks all the monitors for new data, and issue the related errors
            # if their predicate triggers
            def poll
                monitors.each do |m|
                    m.poll(instance_for(model.root).resolve)
                end
            end

            # Checks whether the table is attached to all its data sources
            def ready?
                @monitors_resolved && monitors.all?(&:ready?)
            end
        end
    end
end
