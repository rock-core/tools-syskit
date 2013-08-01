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

            def initialize(root_task, arguments = Hash.new, instances = Hash.new, options = Hash.new)
                super(root_task, arguments, instances, options)
                options = Kernel.validate_options options, :on_replace => :drop
                root_task.poll(options) do
                    poll
                end
                @monitors = Array.new
                resolve_monitors
            end

            # Instanciates all data monitor registered on this table's models
            # and stores the new monitors in {#monitors}
            def resolve_monitors
                model.each_task do |coordination_task_model|
                    if coordination_task_model.respond_to?(:instanciate)
                        root_task.depends_on(task_instance = coordination_task_model.instanciate(root_task.plan))
                        instance_for(coordination_task_model).bind(task_instance)
                    end
                end

                monitors_m = model.each_monitor.to_a
                model.validate_monitors(monitors_m)
                monitors.concat(monitors_m.map { |m| m.bind(self) })
            end

            # Checks all the monitors for new data, and issue the related errors
            # if their predicate triggers
            def poll
                monitors.each do |m|
                    m.poll(instance_for(model.root).resolve)
                end
            end
        end
    end
end
