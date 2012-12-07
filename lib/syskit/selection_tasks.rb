module Syskit
    # Requirement modification task that allows to add a single definition
    # or task to the requirements and inject the result into the plan
    class SingleRequirementTask < Roby::Task
        def self.allocate_id
            @@single_requirement_id += 1
        end
        @@single_requirement_id = 0

        def executable?
            super && requirements
        end

        attr_accessor :requirements

        # Creates the subplan required to add the given task to the plan
        def self.subplan(new_spec, *args)
            root = new_spec.create_proxy_task
            planner = self.new
            planner.requirements = new_spec
            root.should_start_after(planner)
            planner.schedule_as(root)
            root.planned_by(planner)
            root
        end
    end

    def self.require_task(name_or_model)
        SingleRequirementTask.subplan(name_or_model)
    end
end

