module Syskit
    module Runtime
        def self.apply_requirement_modifications(plan)
            tasks = plan.find_tasks(Syskit::InstanceRequirementsTask).running.to_a
            if !tasks.empty?
                begin
                    plan.orocos_engine.resolve
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

