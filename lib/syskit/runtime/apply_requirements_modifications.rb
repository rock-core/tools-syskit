module Syskit
    module Runtime
        def self.apply_requirement_modifications(plan)
            tasks = plan.find_tasks(RequirementModificationTask).running.to_a
            
            if Roby.app.orocos_engine.modified?
                # We assume that all requirement modification have been applied
                # by the RequirementModificationTask instances. They therefore
                # take the blame if something fails, and announce a success
                begin
                    Roby.app.orocos_engine.resolve
                    tasks.each do |t|
                        t.emit :success
                    end
                rescue Exception => e
                    if tasks.empty?
                        # No task to take the blame ... we'll have to shut down
                        raise 
                    end
                    tasks.each do |t|
                        t.emit(:failed, e)
                    end
                end
            end
        end
    end
end

