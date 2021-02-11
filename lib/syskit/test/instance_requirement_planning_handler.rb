# frozen_string_literal: true

require "roby/test/spec"
require "syskit/test/execution_expectations"

module Syskit
    module Test # :nodoc:
        # Planning handler for #roby_run_planner that handles
        # InstanceRequirementsTask
        class InstanceRequirementPlanningHandler
            # @param [Spec] test
            def initialize(test)
                @test = test
            end

            def start(tasks)
                @plan, @planning_tasks = prepare(tasks)

                starting_tasks = @planning_tasks.find_all do |t|
                    t.start! if t.pending?
                    t.starting?
                end
                return apply_requirements if starting_tasks.empty?

                starting_tasks.each do |t|
                    t.start_event.on do |_|
                        apply_requirements if starting_tasks.all?(&:running?)
                    end
                end
            end

            # @api private
            #
            # Validate the argument to {#start} and return the plan and planning
            # tasks the handler should work on
            def prepare(tasks)
                plan = tasks.first.plan
                planning_tasks = tasks.map do |t|
                    unless (planning_task = t.planning_task)
                        raise ArgumentError, "#{t} does not have a planning task"
                    end

                    planning_task
                end

                [plan, planning_tasks]
            end

            def apply_requirements
                @plan.syskit_start_async_resolution(
                    @planning_tasks,
                    validate_generated_network:
                        @test.syskit_run_planner_validate_network?,
                    compute_deployments:
                        @test.syskit_run_planner_deploy_network?
                )
            end

            def finished?
                Thread.pass

                if @plan.syskit_has_async_resolution?
                    return unless @plan.syskit_finished_async_resolution?

                    error = @plan.syskit_apply_async_resolution_results
                    return true if error
                    return unless @test.syskit_run_planner_stub?

                    root_tasks = @planning_tasks.map(&:planned_task)
                    stub_network = StubNetwork.new(@test)

                    # NOTE: this is a run-planner equivalent to syskit_stub_network
                    # we will have to investigate whether we could implement one with
                    # the other (probably), but in the meantime we must keep both
                    # in sync
                    mapped_tasks = @plan.in_transaction do |trsc|
                        mapped_tasks =
                            stub_network.apply_in_transaction(trsc, root_tasks)
                        trsc.commit_transaction
                        mapped_tasks
                    end

                    stub_network.announce_replacements(mapped_tasks)
                    stub_network.remove_obsolete_tasks(mapped_tasks)
                end
                @planning_tasks.all?(&:finished?)
            end

            # Module that should be included in all classes meant to use the
            # run_planners method with Syskit
            #
            # It defines the options that allow to tune what happens during
            # Syskit network generation.
            module Options
                def setup
                    @syskit_run_planner_stub = true
                    @syskit_run_planner_validate_network = false
                    @syskit_run_planner_deploy_network = false

                    super
                end

                # Whether the network should be stubbed, that is any abstract
                # task, missing device or argument be generated for the duration
                # of the test
                #
                # The default is true
                def syskit_run_planner_stub?
                    @syskit_run_planner_stub
                end

                # Control {#syskit_run_planner_stub?}
                attr_writer :syskit_run_planner_stub

                # Whether the network should be validated for e.g. duplicate
                # device use or abstract tasks
                #
                # The default is false
                def syskit_run_planner_validate_network?
                    @syskit_run_planner_validate_network
                end

                # Control {#syskit_run_planner_validate_network?}
                attr_writer :syskit_run_planner_validate_network

                # Whether the network should be deployed
                #
                # The default is false
                def syskit_run_planner_deploy_network?
                    @syskit_run_planner_deploy_network
                end

                # Control {#syskit_run_planner_deploy_network?}
                attr_writer :syskit_run_planner_deploy_network

                # Set deployment and validation option for the duration of its
                # given block
                #
                # @param [Boolean] stub if false, turn off stubbing as well
                def syskit_run_planner_with_full_deployment(stub: true)
                    flags = [@syskit_run_planner_deploy_network,
                             @syskit_run_planner_validate_network,
                             @syskit_run_planner_stub]

                    @syskit_run_planner_deploy_network = true
                    @syskit_run_planner_validate_network = true
                    @syskit_run_planner_stub = stub
                    yield
                ensure
                    @syskit_run_planner_deploy_network,
                        @syskit_run_planner_validate_network,
                        @syskit_run_planner_stub = *flags
                end
            end
        end
        Roby::Test::Spec.roby_plan_with(
            Component.match.with_child(InstanceRequirementsTask),
            InstanceRequirementPlanningHandler
        )

        Roby::Test::ExecutionExpectations.include ExecutionExpectations
    end
end
