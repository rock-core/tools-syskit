module Orocos
    module RobyPlugin
        class InternalError < RuntimeError; end
        class ConfigError < RuntimeError; end
        class SpecError < RuntimeError; end


        class Ambiguous < SpecError; end

        class TaskAllocationFailed < SpecError
            attr_reader :task_parents
            attr_reader :abstract_task
            def initialize(task)
                @abstract_task = task
                @task_parents = abstract_task.
                    enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                    map do |parent_task|
                        options = parent_task[abstract_task,
                            Roby::TaskStructure::Dependency]
                        [options[:roles], parent_task]
                    end
            end

            def pretty_print(pp)
                pp.text "cannot find a concrete implementation for #{abstract_task}"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(task_parents) do |role, parent|
                        pp.text "child #{role.to_a.first} of #{parent.to_short_s}"
                    end
                end
            end
        end

        class AmbiguousTaskAllocation < TaskAllocationFailed
            attr_reader :candidates

            def initialize(task, candidates)
                super(task)
                @candidates    = candidates
            end

            def pretty_print(pp)
                pp.text "there are multiple candidates to implement the abstract task #{abstract_task}"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(task_parents) do |role, parent|
                        pp.text "child #{role.to_a.first} of #{parent.to_short_s}"
                    end
                end
                pp.breakable
                pp.text "you must select one of the candidates using the 'use' statement"
                pp.breakable
                pp.text "possible candidates are"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |task|
                        pp.text task.to_short_s
                    end
                end
            end
        end

        class MissingDeployments < SpecError
            attr_reader :tasks

            def initialize(tasks)
                @tasks = Hash.new
                tasks.each do |task|
                    parents = task.
                        enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                        map do |parent_task|
                            options = parent_task[task,
                                Roby::TaskStructure::Dependency]
                            [options[:roles].to_a.first, parent_task]
                        end
                    @tasks[task] = parents
                end
            end

            def pretty_print(pp)
                pp.text "cannot find a deployment for the following tasks"
                tasks.each do |task, parents|
                    pp.breakable
                    pp.text task.to_s
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(parents) do |role, parent_task|
                            pp.text "child #{role} of #{parent_task}"
                        end
                    end
                end
            end
        end
    end
end

