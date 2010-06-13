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
                        Orocos::RobyPlugin::ModalitySelectionTask.new(
                            :service_model => service,
                            :selected_modality => name)
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
                @implementation =
                    if block then block
                    else model.implementation
                    end

                super(arguments)
            end

            # The block that will be called to modify the system's requirements
            attr_accessor :implementation

            ##
            # :method: start!
            #
            # Requests the modifications to be applied
            event :start do |context|
                if !@implementation
                    raise ArgumentError, "no implementation set for this RequirementModificationTask"
                end

                emit :start
            end

            # Defines a requirement modification block for all instances of this
            # task model
            def self.implementation(&block)
                if block
                    @implementation = block
                elsif @implementation
                    @implementation
                elsif superclass.respond_to?(:implementation)
                    superclass.implementation
                end
            end

            poll do
                implementation.call(Roby.app.orocos_engine)
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
                @instance = engine.set(service_model, selected_modality)
            end

            on :stop do |event|
                # Replace this task by the actual task in the network
                plan.replace_task(self, @instance.task)
            end
        end
    end
end

