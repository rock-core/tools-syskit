module Syskit
    module Runtime
        def self.apply_requirement_modifications(plan)
            tasks = plan.find_tasks(Syskit::InstanceRequirementsTask).running.to_a
            if !tasks.empty?
                begin
                    NetworkGeneration::Engine.resolve(plan)
                    tasks.each do |t|
                        t.success_event.emit
                    end
                rescue ::Exception => e
                    tasks.each do |t|
                        t.failed_event.emit(e)
                    end
                end
            end
        end
    end
end

