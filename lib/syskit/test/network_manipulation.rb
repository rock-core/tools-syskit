# frozen_string_literal: true

require "syskit/test/stubs"
require "syskit/test/stub_network"
require "syskit/test/instance_requirement_planning_handler"

# This is essentially required by the expect_execution harness
# rubocop:disable Style/MultilineBlockChain

module Syskit
    module Test
        # Network manipulation functionality (stubs, ...) useful in tests
        module NetworkManipulation
            include InstanceRequirementPlanningHandler::Options

            # Whether (false) the stub methods should resolve ruby tasks as ruby
            # tasks (i.e. Orocos::RubyTasks::TaskContext, the default), or
            # (true) as something that looks more like a remote task
            # (Orocos::RubyTasks::RemoteTaskContext)
            #
            # The latter is used in Syskit's own test suite to ensure that we
            # don't call remote methods from within Syskit's own event loop
            attr_predicate :syskit_stub_resolves_remote_tasks?, true

            def setup
                @__test_deployment_group = Models::DeploymentGroup.new
                @__orocos_writers = []
                @__orocos_readers = []
                super
                @__stubs = Stubs.new
            end

            def teardown
                @__orocos_writers.each(&:disconnect)
                @__orocos_readers.each(&:disconnect)
                super
                @__stubs.dispose
            end

            def use_deployment(*args, **options)
                Roby.sanitize_keywords_to_array(args, options)
                @__test_deployment_group.use_deployment(*args, **options)
            end

            def use_ruby_tasks(*args, **options)
                Roby.sanitize_keywords_to_array(args, options)
                @__test_deployment_group.use_ruby_tasks(*args, **options)
            end

            def use_unmanaged_task(*args, **options)
                Roby.sanitize_keywords_to_array(args, options)
                @__test_deployment_group.use_unmanaged_task(*args, **options)
            end

            def syskit_stub_network(root_tasks, remote_task: false)
                StubNetwork.apply(root_tasks, self,
                                  stubs: @__stubs, remote_task: remote_task)
            end

            # @api private
            #
            # Helper used to resolve writer objects
            def resolve_orocos_writer(writer, **policy)
                if writer.respond_to?(:to_orocos_port)
                    writer = Orocos.allow_blocking_calls do
                        writer.to_orocos_port
                    end
                end
                # We can write on LocalInputPort, LocalOutputPort and InputPort
                if writer.respond_to?(:writer)
                    writer = Orocos.allow_blocking_calls do
                        writer.writer(**policy)
                    end
                elsif !writer.respond_to?(:write)
                    raise ArgumentError, "#{writer} does not seem to be a port "\
                        "one can write on"
                end
                writer
            end

            # Write a sample on a given input port
            def syskit_write(writer, *samples)
                writer = syskit_create_writer(writer, type: :buffer, size: samples.size)
                samples.each { |s| writer.write(s) }
            end

            def syskit_create_writer(writer, **policy)
                writer = resolve_orocos_writer(writer, **policy)
                @__orocos_writers << writer if writer.respond_to?(:disconnect)
                writer
            end

            # @api private
            #
            # Helper used to resolve writer objects
            def resolve_orocos_reader(reader, **policy)
                if reader.respond_to?(:to_orocos_port)
                    reader = Orocos.allow_blocking_calls do
                        reader.to_orocos_port
                    end
                end
                # We can write on LocalInputPort, LocalOutputPort and InputPort
                if reader.respond_to?(:reader)
                    reader = Orocos.allow_blocking_calls do
                        reader.reader(**policy)
                    end
                elsif !reader.respond_to?(:read)
                    raise ArgumentError,
                          "#{reader} does not seem to be a port one can read from"
                end
                reader
            end

            def syskit_create_reader(reader, **policy)
                reader = resolve_orocos_reader(reader, **policy)
                @__orocos_readers << reader if reader.respond_to?(:disconnect)
                reader
            end

            def normalize_instanciation_models(to_instanciate)
                # Instanciate all actions until we have a syskit instance
                # requirement pattern
                loop do
                    action_tasks, to_instanciate = to_instanciate.partition do |t|
                        t.respond_to?(:planning_task) &&
                            t.planning_task.pending? &&
                            !t.planning_task.respond_to?(:requirements)
                    end
                    break if action_tasks.empty?

                    action_tasks.each do |action_t|
                        planned = run_planners(action_t, recursive: false)
                        planned_subplan = plan.compute_useful_tasks([planned])
                        to_instanciate += plan.find_tasks.abstract.find_all do |t|
                            planned_subplan.include?(t) &&
                                t.respond_to?(:planning_task) &&
                                t.planning_task
                        end
                    end
                end
                to_instanciate
            end

            def syskit_generate_network(*to_instanciate, add_missions: true)
                placeholders = to_instanciate.map do |obj|
                    obj = obj.to_action if obj.respond_to?(:to_action)
                    plan.add(obj = obj.as_plan)
                    plan.add_mission_task(obj) if add_missions
                    obj
                end.compact
                root_tasks = placeholders.map(&:as_service)
                tasks_to_instanciate = normalize_instanciation_models(placeholders)
                if add_missions
                    execute do
                        tasks_to_instanciate.each do |t|
                            plan.add_mission_task(t)
                            t.planning_task.start! if t.planning_task.pending?
                        end
                    end
                end
                task_mapping = plan.in_transaction do |trsc|
                    engine = NetworkGeneration::Engine.new(plan, work_plan: trsc)
                    mapping = engine.compute_system_network(
                        tasks_to_instanciate.map(&:planning_task),
                        validate_generated_network: false
                    )
                    trsc.commit_transaction
                    mapping
                end
                execute do
                    tasks_to_instanciate.each do |task|
                        replacement = task_mapping[task.planning_task]
                        plan.replace_task(task, replacement)
                        plan.remove_task(task)
                        replacement.planning_task.success_event.emit
                    end
                end
                root_tasks.map(&:task)
            end

            def default_deployment_group
                base = Syskit.conf.deployment_group.dup
                base.use_group!(@__test_deployment_group)
                base
            end

            # Run Syskit's deployer (i.e. engine) on the current plan
            def syskit_deploy(
                *to_instanciate,
                add_mission: true, syskit_engine: nil,
                default_deployment_group: self.default_deployment_group,
                **resolve_options
            )
                to_instanciate = to_instanciate.flatten # For backward-compatibility
                placeholder_tasks = to_instanciate.map do |act|
                    act = act.to_action if act.respond_to?(:to_action)
                    plan.add(task = act.as_plan)
                    plan.add_mission_task(task) if add_mission
                    task
                end.compact
                root_tasks = placeholder_tasks.map(&:as_service)
                placeholder_tasks = normalize_instanciation_models(placeholder_tasks)

                requirement_tasks = placeholder_tasks.map(&:planning_task)

                not_running = requirement_tasks.find_all { |t| !t.running? }
                expect_execution { not_running.each(&:start!) }
                    .to { emit(*not_running.map(&:start_event)) }

                resolve_options = Hash[on_error: :commit].merge(resolve_options)
                begin
                    syskit_engine_resolve_handle_plan_export do
                        syskit_engine ||= Syskit::NetworkGeneration::Engine.new(plan)
                        syskit_engine.resolve(
                            default_deployment_group: default_deployment_group,
                            **resolve_options
                        )
                    end
                rescue StandardError => e
                    expect_execution do
                        requirement_tasks.each { |t| t.failed_event.emit(e) }
                    end.to do
                        requirement_tasks.each do |t|
                            have_error_matching(Roby::PlanningFailedError
                                                .match.with_origin(t))
                        end
                    end
                    raise
                end

                execute do
                    placeholder_tasks.each do |task|
                        plan.remove_task(task)
                    end
                    requirement_tasks.each { |t| t.success_event.emit unless t.finished? }
                end

                root_tasks = root_tasks.map(&:task)
                if root_tasks.size == 1
                    root_tasks.first
                elsif root_tasks.size > 1
                    root_tasks
                end
            end

            def syskit_engine_resolve_handle_plan_export
                failed = false
                yield
            rescue StandardError
                failed = true
                raise
            ensure
                if Roby.app.public_logs?
                    filename = name.tr("/", "_")
                    dataflow_base = filename + "-dataflow"
                    hierarchy_base = filename + "-hierarchy"
                    if failed
                        dataflow_base += "-FAILED"
                        hierarchy_base += "-FAILED"
                    end
                    dataflow = File.join(Roby.app.log_dir, "#{dataflow_base}.svg")
                    hierarchy = File.join(Roby.app.log_dir, "#{hierarchy_base}.svg")
                    while File.file?(dataflow) || File.file?(hierarchy)
                        i ||= 1
                        dataflow = File.join(Roby.app.log_dir,
                                             "#{dataflow_base}.#{i}.svg")
                        hierarchy = File.join(Roby.app.log_dir,
                                              "#{hierarchy_base}.#{i}.svg")
                        i += 1
                    end

                    Graphviz.new(plan).to_file("dataflow", "svg", dataflow)
                    Graphviz.new(plan).to_file("hierarchy", "svg", hierarchy)
                end
            end

            # Create a new task context model with the given name
            #
            # @yield a block in which the task context interface can be
            #   defined
            def syskit_stub_task_context_model(name, &block)
                model = TaskContext.new_submodel(name: name, &block)
                model.orogen_model.extended_state_support
                model
            end

            def syskit_stub_configured_deployment(
                task_model = nil,
                task_name = syskit_default_stub_name(task_model),
                remote_task: syskit_stub_resolves_remote_tasks?,
                register: true, &block
            )
                configured_deployment = @__stubs.stub_configured_deployment(
                    task_model, task_name, remote_task: remote_task, &block
                )
                if register
                    @__test_deployment_group
                        .register_configured_deployment(configured_deployment)
                end
                configured_deployment
            end

            # Create a new stub deployment model that can deploy a given task
            # context model
            #
            # @param [Model<Syskit::TaskContext>,nil] task_model if given, a
            #   task model that should be deployed by this deployment model
            # @param [String] name the name of the deployed task as well as
            #   of the deployment. If not given, and if task_model is provided,
            #   task_model.name is used as default
            # @yield the deployment model context, i.e. a context in which the
            #   same declarations than in oroGen's #deployment statement are
            #   available
            # @return [Models::ConfiguredDeployment] the configured deployment
            def syskit_stub_deployment_model(
                task_model = nil, name = nil, register: true, &block
            )
                @__stubs.stub_deployment_model(
                    task_model, name, register: register, &block
                )
            end

            # Create a new stub deployment instance, optionally stubbing the
            # model as well
            def syskit_stub_deployment(
                name = "deployment", deployment_model = nil,
                remote_task: syskit_stub_resolves_remote_tasks?, &block
            )
                deployment_model ||= syskit_stub_configured_deployment(
                    nil, name, remote_task: remote_task, &block
                )
                task = deployment_model.new(process_name: name, on: "stubs")
                plan.add_permanent_task(task)
                task
            end

            # (see Stubs#stub_conf)
            def syskit_stub_conf(task_m, *conf, data: {})
                @__stubs.stub_conf(task_m, *conf, data: data)
            end

            # (see Stubs#stub_device)
            def syskit_stub_device(model, **kw)
                @__stubs.stub_device(model, **kw)
            end

            # (see Stubs#stub_requirements)
            def syskit_stub_requirements(model, **options, &block)
                @__stubs.stub_requirements(model, **options, &block)
            end

            def syskit_default_stub_name(_model)
                @__stubs.default_stub_name
            end

            # (see Stubs#stub_attached_device)
            def syskit_stub_attached_device(bus, **kw)
                @__stubs.stub_attached_device(bus, **kw)
            end

            # (see Stubs#stub_com_bus)
            def syskit_stub_com_bus(model, **kw)
                @__stubs.stub_com_bus(model, **kw)
            end

            # @deprecated use syskit_stub_requirements instead
            def syskit_stub(*args, **options, &block)
                Roby.warn_deprecated "syskit_stub has been renamed to "\
                    "syskit_stub_requirements to make the difference with "\
                    "syskit_stub_network more obvious"
                syskit_stub_requirements(*args, **options, &block)
            end

            def syskit_start_all_execution_agents
                guard = syskit_guard_against_configure

                agents = plan.each_task.map do |t|
                    t.execution_agent if t.execution_agent && !t.execution_agent.ready?
                end.compact

                not_running = agents.find_all { |t| !t.running? }
                not_ready   = agents.find_all { |t| !t.ready? }
                expect_execution { not_running.each(&:start!) }
                    .to { emit(*not_ready.map(&:ready_event)) }
            ensure
                if guard
                    expect_execution do
                        plan.remove_free_event(guard)
                    end.to_run
                end
            end

            def syskit_start_execution_agents(component, recursive: true)
                guard = syskit_guard_against_start_and_configure

                not_ready = []

                queue = [component]
                until queue.empty?
                    task = queue.shift
                    if (agent = task.execution_agent) && !agent.ready?
                        not_ready << agent
                    end
                    queue.concat(task.each_child.map { |t, _| t }) if recursive
                end

                unless not_ready.empty?
                    expect_execution do
                        not_ready.each { |t| t.start! unless t.running? }
                    end.to { emit(*not_ready.map(&:ready_event)) }
                end
            ensure
                if guard
                    expect_execution do
                        plan.remove_free_event(guard)
                    end.to_run
                end
            end

            def syskit_prepare_configure(
                component, tasks,
                recursive: true, except: Set.new
            )
                component.freeze_delayed_arguments
                tasks << component if component.respond_to?(:setup?)
                return unless recursive

                component.each_child do |child_task|
                    next if except.include?(child_task)

                    if child_task.respond_to?(:setup?)
                        syskit_prepare_configure(child_task, tasks,
                                                 recursive: true, except: except)
                    end
                end
            end

            class NoConfigureFixedPoint < RuntimeError
                attr_reader :tasks
                attr_reader :info
                Info = Struct.new :ready_for_setup, :missing_arguments,
                                  :precedence, :missing

                def initialize(tasks)
                    @tasks = tasks
                    @info = {}
                    tasks.each do |t|
                        precedence = t.start_event.parent_objects(
                            Roby::EventStructure::SyskitConfigurationPrecedence
                        ).to_a
                        missing = precedence.find_all { |ev| !ev.emitted? }
                        info[t] = Info.new(
                            t.ready_for_setup?,
                            t.list_unset_arguments,
                            precedence, missing
                        )
                    end
                end

                def pretty_print(pp)
                    pp.text "cannot find an ordering to configure #{tasks.size} tasks"
                    tasks.each do |t|
                        pp.breakable
                        t.pretty_print(pp)

                        info = self.info[t]
                        pp.nest(2) do
                            pp.breakable
                            pp.text "ready_for_setup? #{info.ready_for_setup}"
                            pp.breakable
                            if info.missing_arguments.empty?
                                pp.text "is fully instanciated"
                            else
                                pp.text "missing_arguments: "\
                                        "#{info.missing_arguments.join(', ')}"
                            end

                            pp.breakable
                            if info.precedence.empty?
                                pp.text "has no should_configure_after constraint"
                            else
                                pp.text "is waiting for #{info.missing.size} events "\
                                    "to happen before continuing, among "\
                                    "#{info.precedence.size}"
                                pp.nest(2) do
                                    info.missing.each do |ev|
                                        pp.breakable
                                        ev.pretty_print(pp)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            # Set this component instance up
            def syskit_configure(
                components = __syskit_root_components,
                recursive: true, except: Set.new
            )
                # We need all execution agents to be started to connect (and
                # therefore configur) the tasks
                syskit_start_all_execution_agents

                components = Array(components)
                return if components.empty?

                tasks = Set.new
                except = except.to_set
                components.each do |component|
                    next if tasks.include?(component)

                    syskit_prepare_configure(component, tasks,
                                             recursive: recursive, except: except)
                end
                plan = components.first.plan
                guard = syskit_guard_against_start_and_configure(tasks)

                pending = tasks.dup.to_set
                until pending.empty?
                    execute do
                        Syskit::Runtime::ConnectionManagement.update(plan)
                    end
                    current_pending = pending.size
                    has_missing_states = false
                    pending.delete_if do |t|
                        t.freeze_delayed_arguments
                        should_setup = Orocos.allow_blocking_calls do
                            if !t.kind_of?(Syskit::TaskContext)
                                !t.setup? && t.ready_for_setup?
                            elsif (state = t.read_current_state)
                                !t.setup? && t.ready_for_setup?(state)
                            else
                                has_missing_states = true
                                false
                            end
                        end
                        if should_setup
                            capture_log(t, :info) do
                                t.setup.execute
                                execution_engine.join_all_waiting_work
                            end
                            raise t.failure_reason if t.failed_to_start?

                            assert t.setup?, "ran the setup for #{t}, but t.setup? "\
                                "does not return true"
                            true
                        else
                            t.setup?
                        end
                    end
                    if !has_missing_states && (current_pending == pending.size)
                        missing_starts = pending.flat_map do |pending_task|
                            pending_task.start_event.parent_objects(
                                Roby::EventStructure::SyskitConfigurationPrecedence
                            ).find_all { |e| e.symbol == :start && !e.emitted? }
                        end

                        missing_starts = missing_starts.map(&:task) - pending.to_a
                        if missing_starts.empty?
                            raise NoConfigureFixedPoint.new(pending),
                                  "cannot configure #{pending.map(&:to_s).join(', ')}"
                        else
                            syskit_start(missing_starts, recursive: false)
                        end
                    end
                end
            ensure
                if guard
                    expect_execution do
                        plan.remove_free_event(guard)
                    end.to_run
                end
            end

            # Exception raised by {#syskit_start} if it cannot find a schedule to start
            # all tasks
            class NoStartFixedPoint < RuntimeError
                attr_reader :tasks

                def initialize(tasks)
                    @tasks = tasks
                end

                def pretty_print(pp)
                    pp.text "cannot find an ordering to start #{tasks.size} tasks"
                    tasks.each do |t|
                        pp.breakable
                        t.pretty_print(pp)
                    end
                end
            end

            # @api private
            def syskit_prepare_start(component, tasks, recursive: true, except: Set.new)
                tasks << component if component.respond_to?(:setup?)
                return unless recursive

                component.each_child do |child_task|
                    next if except.include?(child_task)

                    if child_task.respond_to?(:setup?)
                        syskit_prepare_start(child_task, tasks,
                                             recursive: true, except: except)
                    end
                end
            end

            def syskit_guard_against_configure(
                tasks = [], guard = Roby::EventGenerator.new
            )
                tasks = Array(tasks)
                plan.add_permanent_event(guard)
                plan.find_tasks(Syskit::Component).each do |t|
                    t.should_configure_after(guard) unless t.setup? || tasks.include?(t)
                end
                guard
            end

            def syskit_guard_against_start_and_configure(
                tasks = [], guard = Roby::EventGenerator.new
            )
                plan.add_permanent_event(guard)
                syskit_guard_against_configure(tasks, guard)

                plan.find_tasks(Syskit::Component).each do |t|
                    t.should_start_after(guard) if t.pending? && !tasks.include?(t)
                end
                guard
            end

            def __syskit_root_components
                plan.find_tasks(Syskit::Component)
                    .not_abstract
                    .roots(Roby::TaskStructure::Dependency)
            end

            # Start this component
            def syskit_start(
                components = __syskit_root_components,
                recursive: true, except: Set.new
            )
                components = Array(components)
                return if components.empty?

                tasks = Set.new
                except = except.to_set
                components.each do |component|
                    next if tasks.include?(component)

                    syskit_prepare_start(component, tasks,
                                         recursive: recursive, except: except)
                end
                plan = components.first.plan
                guard = syskit_guard_against_start_and_configure(tasks)

                messages = Hash.new { |h, k| h[k] = [] }
                tasks.each do |t|
                    flexmock(t).should_receive(:info)
                               .and_return { |msg| messages[t] << msg }
                end

                pending = tasks.dup
                until pending.empty?
                    current_pending = pending.size

                    to_start = []
                    pending.delete_if do |t|
                        if t.running?
                            true
                        elsif t.executable?
                            unless t.setup?
                                raise "#{t} is not set up, call #syskit_configure first"
                            end

                            to_start << t
                            true
                        end
                    end

                    unless to_start.empty?
                        expect_execution { to_start.each(&:start!) }
                            .to { emit(*to_start.map(&:start_event)) }
                    end

                    if current_pending == pending.size
                        raise NoStartFixedPoint.new(pending), "cannot start "\
                            "#{pending.map(&:to_s).join(', ')}"
                    end
                end

                messages.each do |t, messages_t|
                    assert messages_t.include?("starting #{t}")
                end

                not_started_t = tasks.find { |t| !t.running? }
                if not_started_t
                    raise "failed to start #{not_started_t}: "\
                        "starting=#{not_started_t.starting?} "\
                        "running=#{not_started_t.running?} "\
                        "finished=#{not_started_t.finished?}"
                end
            ensure
                if guard
                    expect_execution do
                        plan.remove_free_event(guard)
                    end.to_run
                end
            end

            def syskit_wait_ready(
                writer_or_reader,
                component: writer_or_reader.port.to_actual_port.component
            )
                return if writer_or_reader.ready?

                syskit_configure(component) unless component.setup?
                syskit_start(component) unless component.running?

                expect_execution.to do
                    achieve { writer_or_reader.ready? }
                end
            end

            # Deploy the given composition, replacing every single data service
            # and task context by a ruby task context, allowing to then test.
            #
            # @param [Boolean] recursive (false) if true, the method will stub
            #   the children of compositions that are used by the root
            #   composition. Otherwise, you have to refer to them in the original
            #   instance requirements
            #
            # @example reuse toplevel tasks in children-of-children
            #   class Cmp < Syskit::Composition
            #      add PoseSrv, :as => 'pose'
            #   end
            #   class RootCmp < Syskit::Composition
            #      add PoseSrv, :as => 'pose'
            #      add Cmp, :as => 'processor'
            #   end
            #   model = RootCmp.use(
            #      'processor' => Cmp.use('pose' => RootCmp.pose_child))
            #   syskit_stub_deploy_and_start_composition(model)
            def syskit_stub_and_deploy(
                model = subject_syskit_model,
                remote_task: syskit_stub_resolves_remote_tasks?, &block
            )
                if model.respond_to?(:to_str)
                    model = syskit_stub_task_context_model(model, &block)
                end
                tasks = syskit_generate_network(*model, &block)
                tasks = syskit_stub_network(tasks, remote_task: remote_task)
                if model.respond_to?(:to_ary)
                    tasks
                else
                    tasks.first
                end
            end

            # Stub a task, deploy it and configure it
            #
            # This starts the underlying (stubbed) deployment process
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            # @see syskit_stub
            def syskit_stub_deploy_and_configure(
                model = subject_syskit_model, recursive: true,
                as: syskit_default_stub_name(model),
                remote_task: syskit_stub_resolves_remote_tasks?, &block
            )

                root = syskit_stub_and_deploy(
                    model, remote_task: remote_task, &block
                )
                syskit_configure(root, recursive: recursive)
                root
            end

            # Stub a task, deploy it, configure it and start the task and
            # the underlying stub deployment
            #
            # This starts the underlying (stubbed) deployment process
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            # @see syskit_stub
            def syskit_stub_deploy_configure_and_start(
                model = subject_syskit_model,
                recursive: true,
                as: syskit_default_stub_name(model),
                remote_task: syskit_stub_resolves_remote_tasks?, &block
            )

                root = syskit_stub_and_deploy(
                    model, remote_task: remote_task, &block
                )
                syskit_configure_and_start(root, recursive: recursive)
                root
            end

            # Deploy and configure a model
            #
            # Unlike {#syskit_stub_deploy_and_configure}, it does not stub the
            # model, so model has to be deploy-able as-is.
            #
            # @param [#to_instance_requirements] model the requirements to
            #   deploy and configure
            # @param [Boolean] recursive if true, children of the provided model
            #   will be configured as well. Otherwise, only the toplevel task
            #   will
            # @return [Syskit::Component]
            def syskit_deploy_and_configure(model = subject_syskit_model, recursive: true)
                root = syskit_deploy(model)
                syskit_configure(root, recursive: recursive)
                root
            end

            # Deploy, configure and start a model
            #
            # Unlike {#syskit_stub_deploy_configure_and_start}, it does not stub
            # the model, so model has to be deploy-able as-is.
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            def syskit_deploy_configure_and_start(
                model = subject_syskit_model, recursive: true
            )
                root = syskit_deploy(model)
                syskit_configure_and_start(root, recursive: recursive)
            end

            # Configure and start a task
            #
            # Unlike {#syskit_stub_deploy_configure_and_start}, it does not stub
            # the model, so model has to be deploy-able as-is.
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            def syskit_configure_and_start(
                component = __syskit_root_components, recursive: true, except: Set.new
            )
                syskit_configure(component, recursive: recursive, except: except)
                syskit_start(component, recursive: recursive, except: except)
                component
            end

            # Stop a task
            def syskit_stop(task)
                expect_execution { task.stop! }.to { emit task.stop_event }
            end

            # Export the dataflow and hierarchy to SVG
            def syskit_export_to_svg(
                plan = self.plan, suffix: "",
                dataflow_options: {}, hierarchy_options: {}
            )
                basename = "syskit-export-%i%s.%s.svg"

                counter = 0
                Dir.glob("syskit-export-*") do |file|
                    if (m = /syskit-export-(\d+)/.match(file))
                        counter = [counter, Integer(m[1])].max
                    end
                end

                dataflow = format(basename, counter + 1, suffix, "dataflow")
                hierarchy = format(basename, counter + 1, suffix, "hierarchy")
                Syskit::Graphviz
                    .new(plan).to_file("dataflow", "svg", dataflow, **dataflow_options)
                Syskit::Graphviz
                    .new(plan).to_file("hierarchy", "svg", hierarchy, **hierarchy_options)
                puts "exported plan to #{dataflow} and #{hierarchy}"
                [dataflow, hierarchy]
            end

            # Deploy the current plan
            #
            # It uses run_planers, and is therefore able to run method or state
            # machine actions before it checks for the deployment
            #
            # It returns a mapping from the missions as they currently are to
            # the deployed missions
            def deploy_current_plan
                old = plan.find_tasks.mission.to_a
                new = syskit_run_planner_with_full_deployment do
                    run_planners(old, recursive: true)
                end

                Hash[old.zip(new)]
            end
        end
    end
end

# rubocop:enable Style/MultilineBlockChain
