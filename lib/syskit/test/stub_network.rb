# frozen_string_literal: true

module Syskit
    module Test
        # Encapsulated implementation of the network stubbing algorithm
        # exposed as {NetworkManipulation#syskit_stub_network}
        #
        # It's a fairly complex algorithm. The goal here is to avoid exposing all
        # its parts in the test API, while making it easier to test and maintain
        #
        # The entrypoint is {#apply}
        class StubNetwork < Stubs
            # Apply stubbing on the given's test plan
            #
            # @param [Array<Roby::Task>] root_tasks the roots of the dependent subgraph
            #   to consider. The tasks are within test.plan (NOT within the transaction)
            # @param [#execute,#plan] test the test context
            # @param [Stubs] stubs a common stubbing object
            # @param [Boolean] remote_task if false, the stubs will be local ruby
            #   task contexts, meaning that it is possible to read their inputs
            #   and write their outputs. If false, they will be accessed as remote
            #   tasks are. This is mainly used within Syskit's own test suite to
            #   test some of the Syskit APIs
            def self.apply(root_tasks, test, stubs: Stubs.new, remote_task: false)
                new(test, stubs: stubs).apply(root_tasks, remote_task: remote_task)
            end

            def initialize(test, stubs: Stubs.new)
                super()
                @test = test
                @plan = test.plan
                @stubs = stubs
            end

            # Create stubs for services, tags and deployments in an existing network
            #
            # @param [Array<Roby::Task>] root_tasks the roots of the network to work on.
            #   The method will work on any Syskit dependent subgraph which has these
            #   roots, so non-Syskit tasks can be provided
            #
            # @return [Array<Roby::Task>] the transformed root tasks, i.e. either the
            #   root tasks, or the tasks that replace them in the stubbed network
            def apply(root_tasks, remote_task: false)
                mapped_tasks = @plan.in_transaction do |trsc|
                    mapped_tasks = apply_in_transaction(
                        trsc, root_tasks, remote_task: remote_task
                    )
                    trsc.commit_transaction
                    mapped_tasks
                end

                @test.execute do
                    announce_replacements(mapped_tasks)
                    remove_obsolete_tasks(mapped_tasks)
                end
                root_tasks.map { |t, _| mapped_tasks[t] }
            end

            def apply_in_transaction(trsc, root_tasks, remote_task: false)
                mapped_tasks = {}

                syskit_roots, syskit_tasks, non_syskit_tasks =
                    discover_syskit_tasks(trsc, root_tasks)

                syskit_roots =
                    save_mission_or_permanent_status(syskit_roots)

                # We don't touch non-Syskit tasks, just make them their own mapping
                non_syskit_tasks.each { |t| mapped_tasks[t] = t }

                merge_solver, trsc_tasks, trsc_other_tasks =
                    prepare_transaction(trsc, syskit_tasks)

                trsc_tasks.each do |task|
                    stub_device_arguments(task)
                end
                stub_abstract_tasks(
                    trsc, merge_solver,
                    trsc_tasks.find_all(&:abstract?)
                )

                create_missing_deployments(
                    merge_solver, trsc_tasks, remote_task: remote_task
                )

                syskit_tasks.each do |plan_t|
                    replacement_t = merge_solver.replacement_for(plan_t)
                    mapped_tasks[plan_t] = trsc.may_unwrap(replacement_t)
                end

                trsc_new_roots = Set.new
                syskit_roots.each do |root_t, status|
                    replacement_t = mapped_tasks[root_t] || root_t
                    if replacement_t != root_t
                        if root_t.planning_task && !replacement_t.planning_task
                            replacement_t.planned_by trsc[root_t.planning_task]
                        end
                        trsc.send("add_#{status}", replacement_t) if status
                    end
                    trsc_new_roots << trsc[replacement_t]
                end

                NetworkGeneration::SystemNetworkGenerator
                    .remove_abstract_composition_optional_children(trsc)
                trsc.static_garbage_collect(
                    protected_roots: trsc_new_roots | trsc_other_tasks
                )
                NetworkGeneration::SystemNetworkGenerator
                    .verify_task_allocation(
                        trsc, components: trsc_tasks.find_all(&:plan)
                    )
                mapped_tasks
            end

            # Exception raised when some conditions block stubbing of a network
            class CannotStub < RuntimeError
                def initialize(original, stub)
                    @original = original
                    @stub = stub
                    @semantic_merge_blockers =
                        @original.arguments.semantic_merge_blockers(@stub.arguments)
                end

                def pretty_print(pp)
                    pp.text "cannot stub "
                    @original.pretty_print(pp)

                    pp.breakable
                    if @semantic_merge_blockers.empty?
                        pp.text "The reason is unknown. Consider this a Syskit bug"
                        return
                    end

                    pp.text "The following delayed arguments should be made available"
                    pp.nest(2) do
                        @semantic_merge_blockers.each do |name, (arg, _)|
                            pp.breakable
                            pp.text "#{name} "
                            pp.nest(2) do
                                arg.pretty_print(pp)
                            end
                        end
                    end
                end
            end

            # @api private
            #
            # Remove tasks that have been replaced by new tasks during stubbing
            def remove_obsolete_tasks(mapped_tasks)
                mapped_tasks.each do |old, new|
                    @plan.remove_task(old) if old != new
                end
            end

            # @api private
            #
            # Call Plan#replaced for stubbed tasks so that they can be tracked with
            # plan services
            def announce_replacements(mapped_tasks)
                mapped_tasks.each do |old, new|
                    @plan.replaced(old, new) if old != new
                end
            end

            # @api private
            #
            # Helper method that returns the set of syskit tasks to work on based on
            # an arbitrary set of tasks in the plan
            #
            # The method looks at the dependent subgraph of a given set of roots, and
            # extracts the Syskit subgraph within it.
            #
            # @return the set of roots within the Syskit component subnet, the set of
            #   syskit tasks and the set of non-syskit tasks
            def discover_syskit_tasks(trsc, root_tasks)
                dependency_graph =
                    trsc.plan.task_relation_graph_for(Roby::TaskStructure::Dependency)
                tasks = root_tasks.dup
                root_tasks.each do |t|
                    dependency_graph.depth_first_visit(t) { |child_t| tasks << child_t }
                end

                syskit, non_syskit =
                    tasks.partition { |t| t.kind_of?(Syskit::Component) }

                syskit_roots = syskit.find_all do |t|
                    t.each_parent_task.none? { |parent_t| syskit.include?(parent_t) }
                end

                [syskit_roots, syskit, non_syskit]
            end

            # @api private
            #
            # Save the mission/permanent status of the given tasks, to be restored later
            def save_mission_or_permanent_status(tasks)
                # Save the permanent/mission status to re-apply it later
                tasks.map do |t|
                    if @plan.mission_task?(t)
                        [t, :mission_task]
                    elsif @plan.permanent_task?(t)
                        [t, :permanent_task]
                    else
                        [t]
                    end
                end
            end

            # @api private
            #
            # Prepare the transaction on which the stub_network method will work
            def prepare_transaction(trsc, syskit_tasks)
                # We need to add the parents to the transaction so as to keep
                # the existing relationships
                other_tasks = syskit_tasks.each_with_object(Set.new) do |t, s|
                    s.merge(t.each_parent_task)
                end
                other_tasks -= syskit_tasks
                trsc_other_tasks = other_tasks.map { |plan_t| trsc[plan_t] }

                merge_solver = NetworkGeneration::MergeSolver.new(trsc)
                trsc_tasks = syskit_tasks.map do |plan_t|
                    trsc_t = trsc[plan_t]
                    merge_solver.register_replacement(plan_t, trsc_t)
                    trsc_t
                end
                [merge_solver, trsc_tasks, trsc_other_tasks]
            end

            # Create stub devices for each unset device arguments of the given task
            #
            # @param [Syskit::Component] task
            # @return [void]
            def stub_device_arguments(task)
                task.model.each_master_driver_service do |srv|
                    task.arguments[:"#{srv.name}_dev"] ||=
                        stub_device(srv.model, driver: srv)
                end
            end

            # @api private
            #
            # Create deployable stubs for abstract tasks (service and tag
            # placeholders)
            #
            # @param [Array<Syskit::Component>] tasks the set of abstract tasks to work on
            def stub_abstract_tasks(plan, merge_solver, tasks)
                merge_mappings = {}

                stubbed_tags = {}
                tasks.each do |abstract_task|
                    # The task is required as being abstract (usually a
                    # if_already_present tag). Do not stub that
                    next if abstract_task.requirements.abstract?

                    concrete_task =
                        if abstract_task.kind_of?(Syskit::Actions::Profile::Tag)
                            tag_id = [abstract_task.model.tag_name,
                                      abstract_task.model.profile.name]
                            stubbed_tags[tag_id] ||=
                                stub_abstract_component(abstract_task)
                        else
                            stub_abstract_component(abstract_task)
                        end

                    pure_data_service_proxy =
                        abstract_task.placeholder? &&
                        !abstract_task.kind_of?(Syskit::TaskContext)
                    if pure_data_service_proxy
                        plan.replace_task(abstract_task, concrete_task)
                        merge_solver.register_replacement(
                            abstract_task, concrete_task
                        )
                    else
                        plan.add(concrete_task)
                        merge_mappings[abstract_task] = concrete_task
                    end
                end

                apply_merge_mappings(merge_solver, merge_mappings)
            end

            def stub_abstract_component(task)
                task_m = task.concrete_model
                if task_m.placeholder?
                    task_m = stub_placeholder_model(task_m)
                elsif task_m.abstract?
                    task_m = stub_abstract_component_model(task_m)
                end

                arguments = task.arguments.dup
                task_m.each_master_driver_service do |srv|
                    arguments[:"#{srv.name}_dev"] ||=
                        stub_device(srv.model, driver: task_m)
                end
                task_m.new(**arguments)
            end

            # @api private
            #
            # Apply a set of replacements using the merge solver
            def apply_merge_mappings(merge_solver, merge_mappings)
                # NOTE: must NOT call #apply_merge_group with merge_mappings
                # directly. #apply_merge_group "replaces" the subnet represented
                # by the keys with the subnet represented by the values. In
                # other words, the connections present between two keys would
                # NOT be copied between the corresponding values

                merge_mappings.each do |original, replacement|
                    unless replacement.can_merge?(original)
                        raise CannotStub.new(original, replacement),
                              "cannot stub #{original} with #{replacement}, maybe "\
                              "some delayed arguments are not set ?"
                    end
                    merge_solver.apply_merge_group(original => replacement)
                end
                merge_solver.merge_identical_tasks
            end

            def create_missing_deployments(merge_solver, tasks, remote_task:)
                merge_mappings = {}
                tasks.each do |original_task|
                    concrete_task = merge_solver.replacement_for(original_task)
                    needs_new_deployment =
                        concrete_task.kind_of?(TaskContext) &&
                        !concrete_task.execution_agent
                    if needs_new_deployment
                        merge_mappings[concrete_task] =
                            stub_deployment(concrete_task, remote_task: remote_task)
                    end
                end

                merge_mappings.each do |original, replacement|
                    unless original.can_merge?(replacement)
                        raise CannotStub.new(original, replacement),
                              "cannot stub #{original} with #{replacement}, maybe "\
                              "some delayed arguments are not set ?"
                    end
                    # See big comment on apply_merge_group above
                    merge_solver.apply_merge_group(original => replacement)
                end
            end

            def stub_deployment(
                task, remote_task: false, as: task.orocos_name || default_stub_name
            )
                task_m = task.concrete_model
                deployment_model = @stubs.stub_configured_deployment(
                    task_m, as, remote_task: remote_task
                )
                stub_conf(task_m, *task.arguments[:conf])
                task.plan.add(deployer = deployment_model.new)
                deployed_task = deployer.instanciate_all_tasks.first

                new_args = {}
                task.arguments.each do |key, arg|
                    new_args[key] = arg if deployed_task.arguments.writable?(key, arg)
                end
                deployed_task.assign_arguments(**new_args)
                deployed_task
            end
        end
    end
end
