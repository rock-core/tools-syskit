module Orocos
    module RobyPlugin
        class ::Roby::Planning::Planner
            # Declares as many planning method as there are modalities available
            # for +service+.
            #
            # +modalities+ is a set of names, of modalities defined by
            # Engine#define. Each planning method will generate the
            # ModalitySelectionTask instance that will select the given modality
            # for +service+
            def self.modality_selection(service, *modalities)
                modalities.each do |name|
                    describe "selects #{name} for #{service.name}"
                    method(name) do
                        selection = Orocos::RobyPlugin::ModalitySelectionTask.new(
                            :service_model => service,
                            :selected_modality => name)

                        if service < Roby::Task
                            main = service.new
                            main.executable = false
                        else
                            main = service.task_model.new
                        end
                        main.planned_by selection
                        main
                    end
                end
            end
        end

        # Type of task that allows to modify the Orocos/Roby engine's
        # requirements. The modifications will be applied when the task is
        # started, and the task will fail if the modification failed.
        #
        # The task calls the block given to #initialize to modify the
        # requirements. Example:
        #
        #   task = RequirementModificationTask.new do |engine|
        #       engine.remove Driving
        #   end
        #
        # Alternatively, if a common modification needs to be done repeatedly,
        # one can define a task model for it
        #
        #   class StopDriving < Orocos::RobyPlugin::RequirementModificationTask
        #       implementation do |engine|
        #           engine.remove Driving
        #       end
        #   end
        #
        # See also ModalitySelectionTask
        class RequirementModificationTask < Roby::Task
            def initialize(arguments = Hash.new, &block)
                super(arguments)

                @implementation_method =
                    if block
                        check_arity(block, 1)
                        block
                    elsif respond_to?(:implementation)
                        method(:implementation)
                    else
                        raise "no requirement modification block given"
                    end
            end

            ##
            # :method: start!
            #
            # Requests the modifications to be applied
            event :start do |context|
                if !@implementation_method
                    raise ArgumentError, "no implementation set for this RequirementModificationTask"
                end

                @result = @implementation_method.call(Roby.app.orocos_engine)
                emit :start
            end

            # Defines a requirement modification block for all instances of this
            # task model
            def self.implementation(&block)
                if !block
                    raise ArgumentError, "no block given"
                end
                check_arity(block, 1)
                define_method(:implementation, &block)
            end

            # If the modification result can be identified by a single task,
            # returns it. Otherwise, returns nil.
            def result_task
                if @result
                    if @result.respond_to?(:task)
                        @result.task
                    elsif @result.respond_to?(:to_task)
                        @result.to_task
                    end
                end
            end

            on :success do |event|
                result_task = self.result_task

                planned = planned_tasks.to_a
                if result_task && planned.size == 1
                    # Replace this result_task by the actual result_task in the network
                    plan.replace_task(planned.first, result_task)

                    # When the result task either finishes or is finalized,
                    # remove the corresponding instance from the requirements
                    result_task.on :stop do |event|
                        Roby.app.orocos_engine.removed(@result)
                    end
                    result_task.when_finalized do
                        if result_task.pending?
                            Roby.app.orocos_engine.removed(@result)
                        end
                    end
                end
            end
        end

        # Type of task that allows to select a particular modality. I.e., it
        # removes any running instance of a particular service and replaces it
        # with the defined modality given to 'selected_modality'
        #
        # In the following example, the hovering service is selected for the
        # Driving service. 'hovering' has been previously defined by
        # Engine#define
        #
        #   ModalitySelectionTask.new :service_model => Driving,
        #       :selected_modality => 'hovering'
        #
        # See also Roby::Planning::Planner.modality_selection
        class ModalitySelectionTask < RequirementModificationTask
            argument :service_model
            argument :selected_modality

            implementation do |engine|
                engine.set(service_model, selected_modality)
            end
        end
    end
end

