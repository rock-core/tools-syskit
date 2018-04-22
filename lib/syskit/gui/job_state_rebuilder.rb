require 'roby/droby/plan_rebuilder'
module Syskit
    module GUI
        class JobStateRebuilder < Roby::DRoby::PlanRebuilder
            def initialize(job_item_model, *args, **options)
                super(*args, **options)
                @init_done = false
                @job_item_model = job_item_model
            end

            def init_done?
                @init_done
            end

            def init_done!
                @init_done = true
            end

            def garbage_task(*)
                task = super
                @job_item_model.garbage_task(task)
            end

            def generator_fired(*)
                event = super
                return unless event.respond_to?(:task)
                @job_item_model.queue_generator_fired(event)
            end

            def scheduler_report_pending_non_executable_task(time, msg, *args)
                return unless init_done?

                msg, *args = super
                formatted_msg = Roby::Schedulers::State.format_message_into_string(
                    msg, *args)
                args.each do |obj|
                    if obj.kind_of?(Roby::Task)
                        @job_item_model.queue_rebuilder_notification(
                            obj, nil, formatted_msg,
                            JobItemModel::NOTIFICATION_SCHEDULER_PENDING)
                    end
                end
            end

            def scheduler_report_trigger(time, generator)
                generator = super
            end

            def scheduler_report_holdoff(time, msg, task, *args)
                return unless init_done?

                msg, task, *args = super
                formatted_msg = Roby::Schedulers::State.format_message_into_string(
                    msg, *args)
                @job_item_model.queue_rebuilder_notification(task, nil, formatted_msg,
                    JobItemModel::NOTIFICATION_SCHEDULER_HOLDOFF)
            end

            def scheduler_report_action(time, msg, task, *args)
                msg, task, *args = super
                formatted_msg = Roby::Schedulers::State.format_message_into_string(
                    msg, *args)
                @job_item_model.queue_rebuilder_notification(task, time, formatted_msg,
                    JobItemModel::NOTIFICATION_SCHEDULER_ACTION)
            end
        end
    end
end
