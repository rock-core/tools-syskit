module Syskit
    module Runtime
        def self.apply_requirement_modifications(plan)
            return if plan.syskit_engine.disabled?

            tasks = plan.find_tasks(Syskit::InstanceRequirementsTask).running.to_a
            if plan.syskit_engine.forced_update? || !tasks.empty?
                begin
                    plan.syskit_engine.resolve
                    tasks.each do |t|
                        t.emit :success
                    end
                rescue ::Exception => e
                    tasks.each do |t|
                        t.emit(:failed, e)
                    end
                end
            end
        end
    end
end

