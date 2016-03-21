module Syskit
    module Runtime
        module PlanExtension
            attr_accessor :syskit_resolution_pool
            attr_accessor :syskit_current_resolution

            def syskit_has_async_resolution?
                !!@syskit_current_resolution
            end

            def syskit_start_async_resolution(requirement_tasks)
                @syskit_resolution_pool ||= Concurrent::CachedThreadPool.new
                @syskit_current_resolution = NetworkGeneration::Async.new(self, thread_pool: syskit_resolution_pool)
                syskit_current_resolution.start(requirement_tasks)
            end

            def syskit_cancel_async_resolution
                syskit_current_resolution.cancel
                @syskit_current_resolution = nil
            end

            def syskit_finished_async_resolution?
                syskit_current_resolution.finished?
            end

            def syskit_valid_async_resolution?
                syskit_current_resolution.valid?
            end

            def syskit_join_current_resolution
                syskit_current_resolution.join
                Runtime.apply_requirement_modifications(self)
            end

            def syskit_apply_async_resolution_results
                syskit_current_resolution.apply
                @syskit_current_resolution = nil
            end
        end

        def self.apply_requirement_modifications(plan, force: false)
            if plan.syskit_has_async_resolution?
                # We're already running a resolution, make sure it is not
                # obsolete
                if force || !plan.syskit_valid_async_resolution?
                    plan.syskit_cancel_async_resolution
                elsif plan.syskit_finished_async_resolution?
                    running_requirement_tasks = plan.find_tasks(Syskit::InstanceRequirementsTask).running
                    begin
                        plan.syskit_apply_async_resolution_results
                    rescue ::Exception => e
                        running_requirement_tasks.each do |t|
                            t.failed_event.emit(e)
                        end
                        return
                    end
                    running_requirement_tasks.each do |t|
                        t.success_event.emit
                    end
                    return
                end
            end

            if !plan.syskit_has_async_resolution?
                if force || plan.find_tasks(Syskit::InstanceRequirementsTask).running.any? { true }
                    requirement_tasks = NetworkGeneration::Engine.discover_requirement_tasks_from_plan(plan)
                    if !requirement_tasks.empty?
                        # We're not resolving anything, but new IR tasks have been
                        # started. Deploy them
                        plan.syskit_start_async_resolution(requirement_tasks)
                    end
                end
            end
        end
    end
end

Roby::ExecutablePlan.include Syskit::Runtime::PlanExtension

