# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # This collects resolution errors so they can be raised. Useful for testing
        # contexts, like Syskit::Test::NetworkManipulation.
        class PartialNetworkResolution < Roby::ExceptionBase
            def initialize(errors)
                original_errors = errors.flat_map(&:original_exception)
                super(original_errors)
            end
        end

        # Reports the result of the network generation application.
        SystemNetworkPlanApplyResult =
            Struct.new :instance_requirement_tasks, :errors, keyword_init: true do
                def error?
                    !errors.empty?
                end
            end

        # This is used to capture failures during the network generation process. Each
        # failure bundles the toplevel tasks that are related to the task that originates
        # the failure. It should be transformed into a ResolutionError for each related
        # task and propagated.
        InternalResolutionFailure =
            Struct.new(:failed_task, :merge_solver, :plan,
                       :original_exception, :message) do
                # Constructor for the InternalResolutionFailure.
                #
                # Takes an array of toplevel tasks with their index in the toplevel tasks
                # array. Optionally, one can provide the original exception and the error
                # message as well.
                def initialize(
                    failed_task, original_exception, merge_solver, plan
                )
                    self.failed_task = failed_task
                    self.merge_solver = merge_solver
                    self.plan = plan
                    self.original_exception = original_exception
                end

                # Convert to ResolutionError by replacing the requirement of a failed task
                # with its toplevel version.
                #
                # @return [ResolutionError]
                def to_resolution_errors(instance)
                    ResolutionError.new(instance, original_exception)
                end
            end

        # Wraps errors that happened during the network generation and deployment.
        #
        # The tasks that relate with wrapped errors are removed from the transaction,
        # alongside with anything that depend on them.
        #
        # This is not meant to be raised, instead it should be propagated using the
        # execution engine error handling.
        class ResolutionError
            attr_reader :planned_task, :planning_task, :original_exception

            def initialize(failed_task, original_exception)
                validate(failed_task)

                @original_exception = original_exception
                @planned_task = failed_task.planned_task
                @planning_task = failed_task
            end

            def validate(failed_task)
                raise ArgumentError, "provided no failed task" unless failed_task

                return if failed_task.planned_task

                raise ArgumentError,
                      "provided task #{failed_task} has no planned_task"
            end
        end

        # Captures resolution failures during the network generation process and process
        # them into resolution errors. The resolution errors have the necessary
        # information to propagate the errors in other contexts.
        class ResolutionErrorHandler
            # The currently registered failures
            attr_reader :resolution_failures

            def initialize(plan, merge_solver)
                @resolution_failures = []
                @plan = plan
                @merge_solver = merge_solver
            end

            def register_resolution_failures_from_exception(tasks, exception)
                tasks = [tasks] unless tasks.kind_of? Array
                tasks.each do |task|
                    failures =
                        failures_from_exception([task], @plan, @merge_solver, exception)
                    failures.each do |failure|
                        @resolution_failures << failure
                    end
                end
            end

            # Find the index of the toplevel tasks that depend on the given task
            #
            # These tasks are in the work plan. The engine will map them to
            # the corresponding tasks in the real plan
            #
            # @param [Syskit::Component] task the task with are depended by the toplevel
            #   tasks
            # @param [Array<Syskit::Component>] toplevel_tasks the list of all the
            #   toplevel tasks
            # @param [Roby::Plan] plan the plan on which we are working
            # @param [NetworkGeneration::MergeSolver] merge_solver the merge solver object
            #    with records with the task replacements so far
            # @return [Array<Syskit::Component, Integer>] the list of toplevel tasks
            #   depending on the given task and their indexes in the provided list of all
            #   toplevel tasks
            def find_index_of_toplevel_tasks_depending_on(
                task, toplevel_tasks, plan, merge_solver
            )
                return [] unless toplevel_tasks

                # Build the mapping of the toplevel task into the actual task
                # in the plan that represents it
                toplevel_tasks_indexes =
                    toplevel_tasks
                    .each_with_index
                    .group_by { |t, _i| merge_solver.replacement_for(t) }
                    .transform_values { |v| v.flatten[1] }

                inv_dependency_graph =
                    plan
                    .task_relation_graph_for(Roby::TaskStructure::Dependency)
                    .reverse

                indexes = []
                inv_dependency_graph.depth_first_visit(task) do |parent|
                    if (index = toplevel_tasks_indexes[parent])
                        indexes << index
                    end
                end
                indexes
            end

            def failures_from_exception(tasks, plan, merge_solver, exception)
                tasks.map do |task|
                    NetworkGeneration::InternalResolutionFailure.new(
                        task, exception, merge_solver.dup, plan.dup
                    )
                end
            end

            def process_failures(required_instances)
                requirement_tasks = required_instances.keys
                toplevel_tasks = required_instances.values

                @resolution_failures.flat_map do |failure|
                    failed_task = failure.failed_task
                    indexes = find_index_of_toplevel_tasks_depending_on(
                        failed_task, toplevel_tasks, failure.plan, failure.merge_solver
                    )
                    indexes.map do |i|
                        instance = requirement_tasks[i]
                        failure.to_resolution_errors(instance)
                    end
                end
            end

            # Cleanup the requirement tasks and toplevel tasks that encountered resolution
            # failures.
            #
            # The resolution errors are used to resolve which tasks should be cleaned up.
            # Both requirement tasks and toplevel tasks remain one to one mappings of each
            # other after this operation.
            def cleanup_resolution_errors(
                resolution_errors, required_instances, work_plan
            )
                resolution_errors.each do |error|
                    requirement_task = error.planning_task
                    required_instances.delete requirement_task
                end
                return [] if resolution_errors.empty?

                NetworkGeneration.debug "cleanup up after error resolution"
                protected_tasks = required_instances.values.map do |v|
                    @merge_solver.replacement_for(v)
                end

                removed_tasks = []
                work_plan
                    .static_garbage_collect(protected_roots: protected_tasks) do |obj|
                        NetworkGeneration.debug { "  removing #{obj}" }
                        # Remove tasks that are not useful anymore
                        @plan.remove_task(obj)
                        removed_tasks << obj
                    end
                @resolution_failures.clear

                removed_tasks
            end
        end

        # A resolution error handler that raises instead of capturing the error
        class RaiseErrorHandler
            def register_resolution_failures_from_exception(_tasks, exception)
                raise exception
            end

            # Noop to satisfy the resolution error handler interface. Should return no
            # errors, since it raises if any errors happened
            def process_failures(*)
                []
            end

            def cleanup_resolution_errors(*); end
        end
    end
end
