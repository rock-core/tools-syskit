module Orocos
    module RobyPlugin
        class Robot
            def initialize
                @com_busses = Hash.new
                @devices    = Hash.new
            end

            attr_reader :com_busses
            attr_reader :devices

            def com_bus(name)
                com_busses[name] = CommunicationBus.new(self, name)
            end

            def through(com_bus, &block)
                bus = com_busses[com_bus]
                if !bus
                    raise SpecError, "communication bus #{com_bus} does not exist"
                end
                bus.through(&block)
                bus
            end

            def device(name, options = Hash.new)
                if devices[name]
                    raise SpecError, "device #{name} is already defined"
                end

                devices[name] = Device.new_submodel(name, options)
            end
        end

        class SystemModel
            include CompositionModel

            attr_reader :robot
            def device(name)
                robot.devices[name]
            end
            attribute(:subsystems) { Hash.new }

            attribute(:configuration) { Hash.new }

            def initialize
                Roby.app.orocos_tasks.each do |name, model|
                    subsystems[name] = model
                end
                @system = self
            end

            def robot(&block)
                if !@robot
                    new_model = Robot.new
                    @robot = new_model
                end
                if block_given?
                    @robot.instance_eval(&block)
                end
                @robot
            end

            def load_all_models
                subsystems['RTT::TaskContext'] = Orocos::Spec::TaskContext
                rtt_taskcontext = Orocos::Generation::Component.standard_tasks.
                    find { |task| task.name == "RTT::TaskContext" }
                Orocos::Spec::TaskContext.task_model = rtt_taskcontext

                Orocos.available_task_models.each do |name, task_lib|
                    next if subsystems[name]

                    task_lib   = Orocos::Generation.load_task_library(task_lib)
                    task_model = task_lib.find_task_context(name)
                    define_task_context_model(task_model)
                end
            end

            def subsystem(name, &block)
                new_model = Composition.new_submodel(name, self)
                subsystems[name] = new_model
                new_model.instance_eval(&block)
                new_model
            end

            def get(name)
                subsystems[name]
            end

            def configure(task_model, &block)
                task = get(task_model)
                if task.configure_block
                    raise SpecError, "#{task_model} already has a configure block"
                end
                task.configure_block = block
                self
            end

            def resolve_models
                subsystems.each_value do |task|
                    if task.respond_to?(:resolve_model)
                        task.resolve_model
                    end
                end
            end

            def pretty_print(pp)
                inheritance = Hash.new { |h, k| h[k] = Set.new }
                inheritance["Orocos::Spec::Subsystem"] << "Orocos::Spec::Composition"

                pp.text "Subsystems"
                pp.nest(2) do
                    pp.breakable
                    subsystems.sort_by { |name, sys| name }.
                        each do |name, sys|
                        inheritance[sys.superclass.name] << sys.name
                        pp.text "#{name}: "
                        pp.nest(2) do
                            pp.breakable
                            sys.pretty_print(pp)
                        end
                        pp.breakable
                        end
                end

                pp.breakable
                pp.text "Models"
                queue = [[0, "Orocos::Spec::Subsystem"]]

                while !queue.empty?
                    indentation, model = queue.pop
                    pp.breakable
                    pp.text "#{" " * indentation}#{model}"

                    children = inheritance[model].
                    sort.reverse.
                    map { |m| [indentation + 2, m] }
                    queue.concat children
                end
            end

            #--
            # Note: this method HAS TO BE the last in the file
            def load(file)
                load_dsl_file(file, binding, true, Exception)
                self
            end
        end

        class Engine
            # The plan we are working on
            attr_reader :plan
            # The model we are taking our tasks from
            attr_reader :model

            def initialize(plan, model)
                @plan      = plan
                @model     = model
            end

            def resolve_compositions
                tasks = plan.find_tasks(Orocos::RobyPlugin::Component).
                    to_value_set
                pp tasks

                tasks.each do |task|
                    task.resolve_compositions if task.respond_to?(:resolve_compositions)
                end

                tasks.each do |task|
                    pp task.connections if task.respond_to?(:connections)
                end

                # merge
            end

            def add(name, arguments = Hash.new)
                task_model = model.get(name)
                task_model.instanciate(plan, arguments)
            end

            def merge
                # Get all the tasks we need to consider. That's easy,
                # they all implement the Orocos::RobyPlugin::Component model
                all_tasks = plan.find_tasks(Orocos::RobyPlugin::Component).
                    to_value_set

                remaining = all_tasks.dup
                # First pass, we look into all tasks that have no inputs in
                # +remaining+, check for duplicates and merge the duplicates

                # Second pass. The remaining tasks are cycles. For those, we
                # actually extract each of the cycles and merge all at once the
                # cycles that are identical.

            end
        end
    end
end


