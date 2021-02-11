# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Component do
    describe "#specialize" do
        attr_reader :task, :task_m
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @task = task_m.new
        end

        it "should make sure that the task has its own private model" do
            task.specialize
            refute_same task_m, task.model
        end
        it "should ensure that the task's concrete model is still the original model" do
            task.specialize
            assert_same task_m, task.concrete_model
        end
        it "ensures that the task's concrete model is the original model's concrete model" do
            task_m = self.task_m.specialize
            task = task_m.new
            task.specialize
            assert_same self.task_m, task.concrete_model
            assert_same self.task_m, task.model.concrete_model
        end
        it "should ensure that the task's model's concrete model is still the original model" do
            task.specialize
            assert_same task_m, task.model.concrete_model
        end
        it "should be possible to declare that the specialized model provides a service without touching the source model" do
            task.specialize
            srv_m = Syskit::DataService.new_submodel
            task.model.provides srv_m, as: "srv"
            assert task.fullfills?(srv_m)
            assert !task_m.fullfills?(srv_m)
        end
        it "should create a specialized model with a submodel of the oroGen model" do
            task.specialize
            refute_same task_m.orogen_model, task.model.orogen_model
            assert_same task_m.orogen_model, task.model.orogen_model.superclass
        end

        it "should return true if it creates a new model" do
            task_m = Syskit::TaskContext.new_submodel
            task = task_m.new
            assert task.specialize
        end
        it "should not specialize an already specialized model, and return false" do
            task_m = Syskit::TaskContext.new_submodel
            task = task_m.new
            task.specialize
            current_model = task.model
            assert !task.specialize
            assert_same current_model, task.model
        end

        describe "once specialized" do
            it "yields ports from the specialized model" do
                task_m = Syskit::TaskContext.new_submodel do
                    output_port "out", "/double"
                end
                task = task_m.new
                task.out_port
                task.specialize
                assert_equal task.out_port.model.component_model, task.model
            end
            it "yields services from the specialized model" do
                srv_m = Syskit::DataService.new_submodel do
                    output_port "out", "/double"
                end

                task_m = Syskit::TaskContext.new_submodel do
                    output_port "out", "/double"
                    provides srv_m, as: "test"
                end
                task = task_m.new
                task.specialize
                assert_equal task.test_srv.out_port.model.component_model.component_model, task.model
            end
        end
    end

    describe "#fullfilled_model" do
        it "does not include the specialized model in the list of fullfilled models" do
            task_m = Syskit::TaskContext.new_submodel
            task = task_m.new
            task.specialize
            assert_equal [task_m], task.fullfilled_model.first
            specialized_m = task_m.specialize
            assert_equal [task_m], specialized_m.new.fullfilled_model.first
        end
    end

    describe "#provided_models" do
        it "includes the task models" do
            task_m = Syskit::Component.new_submodel
            assert_equal [task_m], task_m.new.provided_models
        end
        it "does not return #model if it is a specialization" do
            task_m = Syskit::Component.new_submodel
            task = task_m.new
            task.specialize
            assert_equal [task_m], task.provided_models
            specialized_m = task_m.specialize
            assert_equal [task_m], specialized_m.new.provided_models
        end
    end

    describe "#require_dynamic_service" do
        attr_reader :task_m, :srv_m, :dyn, :task
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "int"
                dynamic_output_port /\w+_out/, "bool"
                dynamic_input_port /\w+_in/, "double"
            end
            srv_m = @srv_m = Syskit::DataService.new_submodel do
                output_port "out", "bool"
                input_port "in", "double"
            end
            @dyn = task_m.dynamic_service srv_m, as: "dyn" do
                provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
            end
            @task = task_m.new
        end

        it "replaces the task with a specialized version of it" do
            flexmock(task).should_receive(:specialize).once.pass_thru
            task.require_dynamic_service "dyn", as: "service_name"
        end
        it "creates a new dynamic service on the specialized model" do
            bound_service = task.require_dynamic_service "dyn", as: "service_name"
            assert_equal bound_service, task.find_data_service("service_name")
            assert !task_m.find_data_service("service_name")
            assert_same bound_service.model.component_model, task.model
        end
        it "does nothing if requested to create a service that already exists" do
            bound_service = task.require_dynamic_service "dyn", as: "service_name"
            assert_equal bound_service, task.require_dynamic_service("dyn", as: "service_name")
        end
        it "raises if requested to instantiate a service without giving it a name" do
            assert_raises(ArgumentError) { task.require_dynamic_service "dyn" }
        end
        it "raises if requested to instantiate a dynamic service that is not declared" do
            assert_raises(ArgumentError) { task.require_dynamic_service "nonexistent", as: "name" }
        end
        it "raises if requested to instantiate a service that already exists but is not compatible with the dynamic service model" do
            task_m.provides Syskit::DataService.new_submodel, as: "srv"
            assert_raises(ArgumentError) { task.require_dynamic_service "dyn", as: "srv" }
        end
        it "supports declaring services as slave devices" do
            master_m = Syskit::Device.new_submodel
            slave_m = Syskit::Device.new_submodel

            task_m.driver_for master_m, as: "driver"
            dyn = task_m.dynamic_service slave_m, as: "device_dyn" do
                provides slave_m, as: name, slave_of: "driver"
            end
            task = task_m.new
            task.require_dynamic_service "device_dyn", as: "slave"
            assert_equal [task.model.driver_srv], task.model.each_master_driver_service.to_a
        end

        describe "behaviour in transaction context" do
            before do
                srv_m = Syskit::DataService.new_submodel
                task_m = Syskit::TaskContext.new_submodel
                task_m.dynamic_service srv_m, as: "test" do
                    provides srv_m
                end
                plan.add(@task = task_m.new)
            end

            it "exposes services that are registered on the underlying task's specialized model" do
                task.require_dynamic_service "test", as: "test"
                transaction = create_transaction
                task_p = transaction[task]
                task_p.specialize
                assert task_p.find_data_service("test")
            end
            it "adds new dynamic services only at the transaction level" do
                transaction = create_transaction
                task_p = transaction[task]
                task_p.require_dynamic_service "test", as: "test"
                assert !task.find_data_service("test")
            end
        end
    end

    describe "#can_merge?" do
        attr_reader :srv_m, :task_m, :testing_task, :tested_task
        before do
            srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel do
                argument :arg
                dynamic_service srv_m, as: "dyn" do
                    provides srv_m.new_submodel, as: name
                end
            end
            @testing_task = @task_m.new
            @tested_task = @task_m.new
        end

        it "returns true if tasks are of identical models" do
            assert testing_task.can_merge?(tested_task)
        end
        it "returns true if the tested task has dynamic services" do
            tested_task.require_dynamic_service "dyn", as: "srv"
            assert testing_task.can_merge?(tested_task)
        end
        it "returns true if the testing task has dynamic services" do
            testing_task.require_dynamic_service "dyn", as: "srv"
            assert testing_task.can_merge?(tested_task)
        end
        it "returns true if testing and tested tasks have different dynamic services" do
            tested_task.require_dynamic_service "dyn", as: "srv_1"
            testing_task.require_dynamic_service "dyn", as: "srv_2"
            assert testing_task.can_merge?(tested_task)
        end
        it "returns false if testing and tested tasks have dynamic services with the same name but different models" do
            tested_task.require_dynamic_service "dyn", as: "srv"
            testing_task.require_dynamic_service "dyn", as: "srv"
            assert !testing_task.can_merge?(tested_task)
        end
        it "returns false if the testing task is abstract and the tested task is not" do
            testing_task.abstract = true
            assert !testing_task.can_merge?(tested_task)
        end
        it "returns true if an argument is set on the tested task but not set on the testing task" do
            tested_task.arg = 10
            assert testing_task.can_merge?(tested_task)
        end

        describe "handling of delayed arguments" do
            before do
                @cmp_m = Syskit::Composition.new_submodel
                @cmp_m.argument :arg
                @cmp_m.add(@task_m, as: "test")
                      .with_arguments(arg: Roby::Task.from(:parent_task).arg)
            end

            it "does not merge if the two tasks have from(:parent_task) ... arguments that "\
                "resolve to different values" do
                testing_cmp = @cmp_m.with_arguments(arg: 5).instanciate(plan)
                tested_cmp  = @cmp_m.with_arguments(arg: 10).instanciate(plan)
                refute testing_cmp.test_child.can_merge?(tested_cmp.test_child)
            end
            it "does merge if the two tasks have from(:parent_task) ... arguments that "\
                "resolve to the same value" do
                testing_cmp = @cmp_m.with_arguments(arg: 10).instanciate(plan)
                tested_cmp  = @cmp_m.with_arguments(arg: 10).instanciate(plan)
                assert testing_cmp.test_child.can_merge?(tested_cmp.test_child)
                testing_cmp.test_child.merge(tested_cmp.test_child)
                assert_equal 10, testing_cmp.test_child.arg
            end
        end
    end

    describe "#merge" do
        attr_reader :srv_m, :task_m, :task, :merged_task
        before do
            srv_m = @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel do
                dynamic_service srv_m, as: "dyn" do
                    provides (options[:model] || srv_m.new_submodel), as: name, slave_of: options[:master]
                end
            end
            @task = task_m.new
            @merged_task = task_m.new
            plan.add(task)
            plan.add(merged_task)
        end

        it "does not specialize the receiver if the merged task has no dynamic services" do
            flexmock(task).should_receive(:specialize).never
            task.merge(merged_task)
        end
        it "does not instantiate dynamic services that already exist on the receiver" do
            merged_task.specialize
            merged_task.require_dynamic_service "dyn", as: "srv"
            task.specialize
            flexmock(task.model).should_receive(:find_data_service).with("srv").and_return(true)
            flexmock(task.model).should_receive(:provides_dynamic).never
            task.merge(merged_task)
        end
        it "specializes the receiver if the merged task has dynamic services" do
            merged_task.specialize
            merged_task.require_dynamic_service "dyn", as: "srv"
            flexmock(task).should_receive(:specialize).once.pass_thru
            task.merge(merged_task)
        end
        it "adds dynamic services from the merged task" do
            merged_task.specialize
            merged_task.require_dynamic_service "dyn", as: "srv", model: (actual_m = srv_m.new_submodel)
            task.specialize
            flexmock(task.model).should_receive(:provides_dynamic).with(actual_m, {}, as: "srv", slave_of: nil, bound_service_class: Syskit::Models::BoundDynamicDataService).once.pass_thru
            task.merge(merged_task)
        end
        it "adds slave dynamic services as slaves" do
            task_m.provides srv_m, as: "master"
            merged_task.specialize
            merged_task.require_dynamic_service "dyn", as: "srv", model: (actual_m = srv_m.new_submodel), master: "master"
            task.specialize
            flexmock(task.model).should_receive(:provides_dynamic).with(actual_m, {}, as: "srv", slave_of: "master", bound_service_class: Syskit::Models::BoundDynamicDataService).once.pass_thru
            task.merge(merged_task)
        end
        it "specializes the target task regardless of whether the target model was already specialized" do
            task_m = self.task_m.new_submodel
            task_m.provides srv_m, as: "master"
            task_m = task_m.specialize
            merged_task_m = task_m.specialize
            merged_task_m.require_dynamic_service "dyn", as: "srv",
                                                         model: srv_m.new_submodel, master: "master"
            plan.add(merged_task = merged_task_m.new)
            plan.add(task = task_m.new)
            flexmock(task).should_receive(:specialize).once
            task.merge(merged_task)
        end
        it "does not modify its current model unless it is its singleton class" do
            task_m = self.task_m.new_submodel
            task_m.provides srv_m, as: "master"
            merged_task_m = task_m.specialize
            merged_task_m.require_dynamic_service "dyn", as: "srv",
                                                         model: srv_m.new_submodel, master: "master"
            plan.add(task = task_m.new)
            plan.add(merged_task = merged_task_m.new)
            task.merge(merged_task)
            assert task_m.each_required_dynamic_service.empty?
        end
        it "can merge a task built from a specialized model into one that is not specialized" do
            task_m.provides srv_m, as: "master"
            merged_task_m = task_m.specialize
            plan.add(merged_task = merged_task_m.new)
            task.merge(merged_task)
        end
        # This is necessary as the block can do anything, as e.g. create new
        # arguments or events on the task model.
        it "uses #require_dynamic_service to create the new services in order to re-evaluate the block" do
            merged_task.specialize
            merged_task.require_dynamic_service "dyn", as: "srv", argument: 10
            task.specialize
            flexmock(task.model).should_receive(:require_dynamic_service).once
                                .with("dyn", as: "srv", argument: 10)
                                .pass_thru
            task.merge(merged_task)
        end
        describe "handling of default arguments" do
            attr_reader :task_m, :default_arg
            before do
                @task_m = Syskit::Component.new_submodel do
                    argument :arg
                end
                @default_arg = Roby::DefaultArgument.new(10)
            end

            it "propagates default arguments to components that have no argument at all" do
                plan.add(receiver = task_m.new)
                plan.add(argument = task_m.new(arg: default_arg))
                receiver.merge(argument)
                assert_equal default_arg, receiver.arguments.values[:arg]
            end
            it "does not propagate a default argument if the receiver has a default argument set" do
                receiver_arg = Roby::DefaultArgument.new(20)
                plan.add(receiver = task_m.new(arg: receiver_arg))
                plan.add(argument = task_m.new(arg: default_arg))
                receiver.merge(argument)
                assert_equal receiver_arg, receiver.arguments.values[:arg]
            end
            it "overrides default arguments by static ones" do
                plan.add(receiver = task_m.new(arg: default_arg))
                plan.add(argument = task_m.new(arg: 10))
                receiver.merge(argument)
                assert_equal 10, receiver.arguments.values[:arg]
            end
            it "does not propagate a default argument if the receiver has a static argument set" do
                plan.add(receiver = task_m.new(arg: 10))
                plan.add(argument = task_m.new(arg: default_arg))
                receiver.merge(argument)
                assert_equal 10, receiver.arguments.values[:arg]
            end
        end
    end

    describe "#each_required_dynamic_service" do
        it "should yield nothing for plain models" do
            task_m = Syskit::Component.new_submodel
            srv_m = Syskit::DataService.new_submodel
            task_m.provides srv_m, as: "test"
            assert task_m.new.each_required_dynamic_service.empty?
        end

        it "should yield services instanciated through the dynamic service mechanism" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel
            task_m.dynamic_service srv_m, as: "dyn" do
                provides srv_m, as: name
            end

            model_m = task_m.new_submodel
            srv = model_m.require_dynamic_service "dyn", as: "test"
            task = model_m.new
            assert_equal [srv.bind(task)], task.each_required_dynamic_service.to_a
        end
    end

    describe "#deployment_hints" do
        it "should return requirements.deployment_hints if it is not empty" do
            task = Syskit::Component.new
            task.requirements.deployment_hints << Regexp.new("test")
            assert_equal task.requirements.deployment_hints, task.deployment_hints
        end
        it "should return the merged hints from its parents if requirements.deployment_hints is empty" do
            plan.add(task = Syskit::Component.new)
            parents = (1..2).map do
                t = Syskit::Component.new
                t.depends_on task
                t
            end
            flexmock(parents[0]).should_receive(:deployment_hints).once.and_return([1, 2])
            flexmock(parents[1]).should_receive(:deployment_hints).once.and_return([2, 3])
            assert_equal [1, 2, 3].to_set, task.deployment_hints
        end
    end

    describe "#method_missing" do
        it "returns a matching service if called with the #srv_name_srv handler" do
            task = Syskit::Component.new
            flexmock(task).should_receive(:find_data_service).with("a_service_name").and_return(srv = Object.new)
            assert_same srv, task.a_service_name_srv
        end
        it "raises NoMethodError if called with the #srv_name_srv handler for a service that does not exist" do
            task = Syskit::Component.new
            flexmock(task).should_receive(:find_data_service).with("a_service_name")
            assert_raises(NoMethodError) { task.a_service_name_srv }
        end
        it "returns a matching port if called with the #port_name_port handler" do
            task = Syskit::Component.new
            flexmock(task).should_receive(:find_port).with("a_port_name").and_return(obj = Object.new)
            assert_same obj, task.a_port_name_port
        end
        it "raises NoMethodError if called with the #port_name_port handler for a port that does not exist" do
            task = Syskit::Component.new
            flexmock(task).should_receive(:find_port).with("a_port_name")
            assert_raises(NoMethodError) { task.a_port_name_port }
        end
    end

    describe "#should_configure_after" do
        it "adds a configuration precedence link between the given event and the start event of the receiver" do
            plan.add(component = Syskit::Component.new)
            event = Roby::EventGenerator.new
            flexmock(event).should_receive(:add_syskit_configuration_precedence).once.with(component.start_event)
            component.should_configure_after(event)
        end
    end

    describe "#will_never_setup?" do
        it "returns false" do
            refute Syskit::Component.new.will_never_setup?
        end
    end

    describe "#ready_for_setup?" do
        it "returns true on a blank task" do
            assert Syskit::Component.new.ready_for_setup?
        end
        it "returns false if there are unfullfilled syskit configuration precedence links" do
            plan.add(component = Syskit::Component.new)
            component.should_configure_after(event = Roby::EventGenerator.new)
            assert !component.ready_for_setup?
            component.should_configure_after(Roby::EventGenerator.new)
            execute { event.emit }
            assert !component.ready_for_setup?
        end
        it "returns true if all the parent events in a syskit configuration precedence links are either emitted or unreachable" do
            plan.add(component = Syskit::Component.new)
            component.should_configure_after(event = Roby::EventGenerator.new)
            execute { event.emit }
            component.should_configure_after(event = Roby::EventGenerator.new)
            execute { event.unreachable! }
            assert component.ready_for_setup?
        end
    end

    describe "#specialized_model?" do
        it "should return false on a plain model" do
            assert !Syskit::TaskContext.new_submodel.new.specialized_model?
        end
        it "should return true if #specialize has been called on the model" do
            assert Syskit::TaskContext.new_submodel.specialize.new.specialized_model?
        end
        it "should return true if #specialize has been called on the instance" do
            object = Syskit::TaskContext.new_submodel.new
            object.specialize
            assert object.specialized_model?
        end
    end

    describe "#commit_transaction" do
        it "specializes the real task if the proxy was specialized" do
            task_m = Syskit::TaskContext.new_submodel
            plan.add(task = task_m.new)
            plan.in_transaction do |trsc|
                trsc[task].specialize
                trsc.commit_transaction
            end
            assert task.specialized_model?
        end

        it "creates dynamic ports" do
            task_m = Syskit::TaskContext.new_submodel do
                dynamic_output_port /\w+/, nil
            end
            dynport = task_m.orogen_model.dynamic_ports.find { true }

            plan.add(task = task_m.new)
            plan.in_transaction do |trsc|
                proxy = trsc[task]
                proxy.instanciate_dynamic_output_port("name", "/double", dynport)
                trsc.commit_transaction
            end
            assert task.model.find_output_port("name")
        end

        it "creates dynamic services" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel
            dyn_m  = task_m.dynamic_service srv_m, as: "test" do
                provides srv_m, as: "test"
            end

            plan.add(task = task_m.new)
            plan.in_transaction do |trsc|
                proxy = trsc[task]
                proxy.require_dynamic_service "test", as: "test"
                trsc.commit_transaction
            end
            services = task.each_required_dynamic_service.to_a
            assert_equal 1, services.size
            expected_dyn_srv = task.model.find_dynamic_service("test")
            assert_equal expected_dyn_srv, services.first.model.dynamic_service
        end
    end

    describe "#to_instance_requirements" do
        it "should list assigned arguments" do
            task_m = Syskit::Component.new_submodel do
                argument :arg
            end
            req = task_m.new(arg: 10).to_instance_requirements
            assert_equal Hash[arg: 10], req.arguments.to_hash
        end
        it "should not list unassigned arguments" do
            task_m = Syskit::Component.new_submodel do
                argument :arg
            end
            req = task_m.new.to_instance_requirements
            assert req.arguments.empty?
        end
        it "should not list unset arguments with defaults" do
            task_m = Syskit::Component.new_submodel do
                argument :arg, default: nil
            end
            req = task_m.new.to_instance_requirements
            assert req.arguments.empty?
        end
    end

    describe "#setup" do
        attr_reader :task, :recorder

        before do
            task = syskit_stub_and_deploy(Syskit::Component.new_submodel)
            @task = flexmock(task)
            @recorder = flexmock
        end

        describe "configuration success" do
            it "calls setup_successful! if the setup is successful" do
                task.should_receive(:perform_setup).once.globally.ordered
                task.should_receive(:setup_successful!).once.globally.ordered.pass_thru
                promise = task.setup.execute
                assert task.setting_up?
                assert !task.setup?
                execution_engine.join_all_waiting_work
                assert !task.setting_up?
                assert task.setup?
            end
        end

        describe "configuration failure" do
            attr_reader :error_m

            before do
                @error_m = error_m = Class.new(RuntimeError)
                task.should_receive(:perform_setup).and_return do |promise|
                    promise.then { raise error_m }
                end
            end

            it "calls #setup_failed! instead of setup_successful! if the setup raises" do
                task.should_receive(:setup_failed!).once.pass_thru
                task.should_receive(:setup_successful!).never
                expect_execution { task.setup.execute }
                    .to { fail_to_start task, reason: Roby::EmissionFailed }
                refute task.setting_up?
                refute task.setup?
            end

            it "marks the underlying task as failed_to_start! if the setup raises" do
                expect_execution { task.setup.execute }.to do
                    fail_to_start(
                        task,
                        reason: Roby::EmissionFailed
                                .match
                                .with_original_exception(error_m)
                    )
                end
            end
        end
    end

    describe "model-level data readers" do
        before do
            @support_task_m = Syskit::TaskContext.new_submodel
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
        end

        it "creates a bound accessor and attaches it on start" do
            @support_task_m.data_reader @task_m.match.out_port, as: "test"
            support_task = syskit_stub_and_deploy(@support_task_m)
            task = syskit_stub_and_deploy(@task_m)
            reader = support_task.test_reader
            assert_equal Syskit::DynamicPortBinding::BoundOutputReader,
                         reader.class

            syskit_configure_and_start(support_task)
            assert reader.valid?
            assert_equal task.out_port, reader.resolved_accessor.port
        end

        it "enumerates the bound readers with each_data_reader" do
            @support_task_m.data_reader @task_m.match.out_port, as: "test"
            support_task = syskit_stub_and_deploy(@support_task_m)
            assert_equal [support_task.test_reader], support_task.each_data_reader.to_a
        end

        it "updates it at runtime" do
            @support_task_m.data_reader @task_m.match.running.out_port, as: "test"
            support_task = syskit_stub_deploy_configure_and_start(@support_task_m)
            task = syskit_stub_deploy_configure_and_start(@task_m)

            reader = support_task.test_reader
            expect_execution.to { achieve { reader.connected? } }

            syskit_stop(task)
            task = syskit_stub_deploy_configure_and_start(@task_m)
            expect_execution.to { achieve { reader.connected? } }
            assert_equal task.out_port, reader.resolved_accessor.port
        end
    end

    describe Syskit::Component::DataAccessorInterface do
        before do
            @reader = Syskit::Component::DataAccessorInterface.new
            flexmock(@reader)
            @writer = Syskit::Component::DataAccessorInterface.new
            flexmock(@writer)

            @task_m = Syskit::Component.new_submodel
            @task = syskit_stub_deploy_and_configure(@task_m)
        end

        it "calls #attach_to_task and #update on start" do
            @task.register_data_reader(@reader)
            @task.register_data_writer(@writer)
            syskit_configure(@task)
            @reader.should_receive(:attach_to_task).with(@task).once
            @reader.should_receive(:update).at_least.once
            @writer.should_receive(:attach_to_task).with(@task).once
            @writer.should_receive(:update).at_least.once
            syskit_start(@task)
        end

        it "calls #attach_to_task and #update immediately if registered at runtime" do
            syskit_start(@task)
            @reader.should_receive(:attach_to_task).with(@task).once
            @reader.should_receive(:update).once
            @writer.should_receive(:attach_to_task).with(@task).once
            @writer.should_receive(:update).once
            @task.register_data_reader(@reader)
            @task.register_data_writer(@writer)
        end

        it "calls #update at each cycle" do
            @task.register_data_reader(@reader)
            @task.register_data_writer(@writer)
            syskit_start(@task)
            @reader.should_receive(:update).at_least.times(10)
            @writer.should_receive(:update).at_least.times(10)
            10.times { execute_one_cycle }
        end

        it "calls #disconnect on stop" do
            @task.register_data_reader(@reader)
            @task.register_data_writer(@writer)
            syskit_start(@task)
            @reader.should_receive(:disconnect).once
            @writer.should_receive(:disconnect).once
            syskit_stop(@task)
        end
    end

    describe "#data_reader" do
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            flexmock(Syskit::DynamicPortBinding::BoundOutputReader)

            @task = syskit_stub_deploy_and_configure(@task_m)
        end

        describe "without a given accessor name" do
            it "creates an unbound accessor" do
                reader = @task.data_reader(@task_m.out_port)
                assert_equal Syskit::DynamicPortBinding::OutputReader, reader.class
                reader.attach_to_task(@task)
                reader.update
                assert_equal @task.out_port, reader.resolved_accessor.port
            end

            it "creates the reader with the specified policy" do
                reader = @task.data_reader(@task_m.out_port, type: :buffer, size: 20)
                assert_equal({ pull: true, type: :buffer, size: 20 },
                             reader.policy)
            end

            it "sets 'pull' to true by default" do
                reader = @task.data_reader(@task_m.out_port)
                assert reader.policy[:pull]
            end

            it "lets the caller override 'pull'" do
                reader = @task.data_reader(@task_m.out_port, pull: false)
                refute reader.policy[:pull]
            end
        end

        describe "when given a name" do
            it "creates a bound accessor" do
                writer = @task.data_reader(@task_m.out_port, as: "test")
                assert_equal Syskit::DynamicPortBinding::BoundOutputReader, writer.class
                writer.attach
                writer.update
                assert_equal @task.out_port, writer.resolved_accessor.port
            end

            it "makes the bound accessor accessible through the _reader accessors" do
                reader = @task.data_reader(@task_m.out_port, as: "test")
                assert_same reader, @task.test_reader
            end

            it "creates the accessor with the specified policy" do
                reader = @task.data_reader(@task_m.out_port, type: :buffer, size: 20)
                assert_equal({ pull: true, type: :buffer, size: 20 },
                             reader.policy)
            end

            it "sets 'pull' to true by default" do
                reader = @task.data_reader(@task_m.out_port)
                assert reader.policy[:pull]
            end

            it "lets the caller override 'pull'" do
                reader = @task.data_reader(@task_m.out_port, pull: false)
                refute reader.policy[:pull]
            end
        end

        it "raises if the port is an output port" do
            e = assert_raises(ArgumentError) do
                @task.data_reader(@task_m.in_port)
            end
            assert_equal "expected #{@task_m.in_port} to be an output port", e.message
        end

        it "does not attach and update the port writer if the task is not running" do
            Syskit::DynamicPortBinding::BoundOutputReader
                .new_instances.should_receive(:attach_to_task).never
            Syskit::DynamicPortBinding::BoundOutputReader
                .new_instances.should_receive(:update).never
            @task.data_reader(@task_m.out_port, as: "test")
        end

        it "attaches created writers on start" do
            writer = @task.data_reader(@task_m.out_port, as: "test")
            flexmock(writer).should_receive(:attach_to_task).with(@task).once
            flexmock(writer).should_receive(:update).at_least.once
            syskit_start(@task)
        end

        it "attaches and updates the port writer if the task is already running" do
            syskit_start(@task)
            Syskit::DynamicPortBinding::BoundOutputReader
                .new_instances.should_receive(:attach_to_task).with(@task).once
            Syskit::DynamicPortBinding::BoundOutputReader
                .new_instances.should_receive(:update).once
            @task.data_reader(@task_m.out_port, as: "test")
        end

        it "disconnects the port writer on stop" do
            writer = @task.data_reader(@task_m.out_port, as: "test")
            syskit_start(@task)
            flexmock(writer).should_receive(:disconnect).once
            syskit_stop(@task)
        end

        describe "deprecated string-based arguments" do
            before do
                @task = syskit_stub_and_deploy(@task_m)
            end

            it "rejects a non-nil 'as' option" do
                e = assert_raises(ArgumentError) do
                    @task.data_reader("out", as: "test")
                end
                assert_equal "cannot provide the 'as' option to the deprecated "\
                             "string-based call to #data_reader", e.message
            end

            it "creates a reader on one of the component's ports" do
                writer = @task.data_reader("out")
                assert_kind_of Syskit::OutputReader, writer
                assert_equal @task.out_port, writer.port
            end

            it "resolves port mapping if accessing a composition's child" do
                srv_m = Syskit::DataService.new_submodel do
                    output_port "srv_out", "/double"
                end
                cmp_m = Syskit::Composition.new_submodel
                @task_m.provides srv_m, as: "test"
                cmp_m.add srv_m, as: "test"

                cmp = syskit_stub_and_deploy(cmp_m.use("test" => @task_m))

                writer = cmp.data_reader("test", "srv_out")
                assert_equal cmp.test_child.out_port, writer.port
            end

            it "falls back to Roby's notion of role if accessing children "\
               "from a non-composition" do
                parent_task = syskit_stub_and_deploy(@task_m)
                parent_task.depends_on @task, role: "test"

                writer = parent_task.data_reader("test", "out")
                assert_equal @task.out_port, writer.port
            end

            it "passes the connection policy" do
                policy = { type: :buffer, size: 20 }
                reader = @task.data_reader("out", **policy)
                assert_equal({ pull: true }.merge(policy), reader.policy)
            end

            it "disconnects the port on task stop" do
                syskit_configure_and_start(@task)
                writer = @task.data_reader("out")
                flexmock(writer).should_receive(:disconnect).once.pass_thru
                syskit_stop(@task)
            end

            it "raises if the given port is an input port" do
                e = assert_raises(ArgumentError) { @task.data_reader("in") }
                assert_equal "#{@task}.in is an input port, expected an output port",
                             e.message
            end

            it "raises if the given port does not exist" do
                e = assert_raises(ArgumentError) { @task.data_reader("does_not_exist") }
                assert_equal "'does_not_exist' is not a port of #{@task}. Known "\
                             "ports are: in, out, state", e.message
            end
        end
    end

    describe "model-level data writers" do
        before do
            @support_task_m = Syskit::TaskContext.new_submodel
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
        end

        it "creates a bound accessor and attaches it on start" do
            @support_task_m.data_writer @task_m.match.in_port, as: "test"
            support_task = syskit_stub_and_deploy(@support_task_m)
            task = syskit_stub_and_deploy(@task_m)
            reader = support_task.test_writer
            assert_equal Syskit::DynamicPortBinding::BoundInputWriter,
                         reader.class

            syskit_configure_and_start(support_task)
            assert reader.valid?
            assert_equal task.in_port, reader.resolved_accessor.port
        end

        it "enumerates the bound writers with each_data_writer" do
            @support_task_m.data_writer @task_m.match.in_port, as: "test"
            support_task = syskit_stub_and_deploy(@support_task_m)
            assert_equal [support_task.test_writer], support_task.each_data_writer.to_a
        end

        it "updates it at runtime" do
            @support_task_m.data_writer @task_m.match.running.in_port, as: "test"
            support_task = syskit_stub_deploy_configure_and_start(@support_task_m)
            task = syskit_stub_deploy_configure_and_start(@task_m)

            writer = support_task.test_writer
            expect_execution.to { achieve { writer.connected? } }

            syskit_stop(task)
            task = syskit_stub_deploy_configure_and_start(@task_m)
            expect_execution.to { achieve { writer.connected? } }
            assert_equal task.in_port, writer.resolved_accessor.port
        end
    end

    describe "#data_writer" do
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            flexmock(Syskit::DynamicPortBinding::BoundInputWriter)

            @task = syskit_stub_deploy_and_configure(@task_m)
        end

        describe "without a given accessor name" do
            it "creates an unbound accessor" do
                writer = @task.data_writer(@task_m.in_port)
                assert_equal Syskit::DynamicPortBinding::InputWriter, writer.class
                writer.attach_to_task(@task)
                writer.update
                assert_equal @task.in_port, writer.resolved_accessor.port
            end

            it "creates the reader with the specified policy" do
                writer = @task.data_writer(@task_m.in_port, type: :buffer, size: 20)
                assert_equal({ type: :buffer, size: 20 },
                             writer.policy)
            end
        end

        describe "when given a name" do
            it "creates a bound accessor" do
                writer = @task.data_writer(@task_m.in_port, as: "test")
                assert_equal Syskit::DynamicPortBinding::BoundInputWriter, writer.class
                writer.attach
                writer.update
                assert_equal @task.in_port, writer.resolved_accessor.port
            end

            it "makes the bound accessor accessible through the _writer accessors" do
                writer = @task.data_writer(@task_m.in_port, as: "test")
                assert_same writer, @task.test_writer
            end

            it "creates the writer with the specified policy" do
                writer = @task.data_writer(
                    @task_m.in_port, type: :buffer, size: 20, as: "test"
                )
                assert_equal({ type: :buffer, size: 20 }, writer.policy)
            end
        end

        it "raises if the port is an output port" do
            assert_raises(ArgumentError) do
                @task.data_writer(@task_m.out_port)
            end
        end

        it "does not attach and update the port writer if the task is not running" do
            Syskit::DynamicPortBinding::BoundInputWriter
                .new_instances.should_receive(:attach_to_task).never
            Syskit::DynamicPortBinding::BoundInputWriter
                .new_instances.should_receive(:update).never
            @task.data_writer(@task_m.in_port, as: "test")
        end

        it "attaches created writers on start" do
            writer = @task.data_writer(@task_m.in_port, as: "test")
            flexmock(writer).should_receive(:attach_to_task).with(@task).once
            flexmock(writer).should_receive(:update).at_least.once
            syskit_start(@task)
        end

        it "attaches and updates the port writer if the task is already running" do
            syskit_start(@task)
            Syskit::DynamicPortBinding::BoundInputWriter
                .new_instances.should_receive(:attach_to_task).with(@task).once
            Syskit::DynamicPortBinding::BoundInputWriter
                .new_instances.should_receive(:update).once
            @task.data_writer(@task_m.in_port, as: "test")
        end

        it "disconnects the port writer on stop" do
            writer = @task.data_writer(@task_m.in_port, as: "test")
            syskit_start(@task)
            flexmock(writer).should_receive(:disconnect).once
            syskit_stop(@task)
        end

        describe "deprecated string-based arguments" do
            before do
                @task = syskit_stub_and_deploy(@task_m)
            end

            it "rejects a non-nil 'as' option" do
                e = assert_raises(ArgumentError) do
                    @task.data_writer("in", as: "test")
                end
                assert_equal "cannot provide the 'as' option to the deprecated "\
                             "string-based call to #data_writer", e.message
            end

            it "creates a reader on one of the component's ports" do
                writer = @task.data_writer("in")
                assert_kind_of Syskit::InputWriter, writer
                assert_equal @task.in_port, writer.port
            end

            it "resolves port mapping if accessing a composition's child" do
                srv_m = Syskit::DataService.new_submodel do
                    input_port "srv_in", "/double"
                end
                cmp_m = Syskit::Composition.new_submodel
                @task_m.provides srv_m, as: "test"
                cmp_m.add srv_m, as: "test"

                cmp = syskit_stub_and_deploy(cmp_m.use("test" => @task_m))

                writer = cmp.data_writer("test", "srv_in")
                assert_equal cmp.test_child.in_port, writer.port
            end

            it "falls back to Roby's notion of role if accessing children "\
               "from a non-composition" do
                parent_task = syskit_stub_and_deploy(@task_m)
                parent_task.depends_on @task, role: "test"

                writer = parent_task.data_writer("test", "in")
                assert_equal @task.in_port, writer.port
            end

            it "passes the connection policy" do
                policy = { type: :buffer, size: 20 }
                reader = @task.data_writer("in", **policy)
                assert_equal policy, reader.policy
            end

            it "disconnects the port on task stop" do
                syskit_configure_and_start(@task)
                writer = @task.data_writer("in")
                flexmock(writer).should_receive(:disconnect).once.pass_thru
                syskit_stop(@task)
            end

            it "raises if the given port is an output port" do
                e = assert_raises(ArgumentError) { @task.data_writer("out") }
                assert_equal "#{@task}.out is an output port, expected an input "\
                             "port", e.message
            end

            it "raises if the given port does not exist" do
                e = assert_raises(ArgumentError) { @task.data_writer("does_not_exist") }
                assert_equal "'does_not_exist' is not a port of #{@task}. Known "\
                             "ports are: in, out, state", e.message
            end
        end
    end
end

class TC_Component < Minitest::Test
    DataService = Syskit::DataService
    TaskContext = Syskit::TaskContext

    def dataflow_graph
        plan.task_relation_graph_for(Syskit::Flows::DataFlow)
    end

    def test_get_bound_data_service_using_servicename_srv_syntax
        service_model = DataService.new_submodel
        component_model = TaskContext.new_submodel
        bound_service_model = component_model.provides(service_model, as: "test")
        plan.add(component = component_model.new)
        assert_equal(component.find_data_service("test"), component.test_srv)
    end

    def test_connect_ports
        source_model = Syskit::TaskContext.new_submodel do
            output_port "out", "/double"
        end
        sink_model = Syskit::TaskContext.new_submodel do
            input_port "out", "/double"
            input_port "other", "/double"
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        source_task.connect_ports(sink_task, %w[out out] => { type: :buffer, size: 20 })
        assert_equal({ %w[out out] => { type: :buffer, size: 20 } },
                     source_task[sink_task, Syskit::Flows::DataFlow])
        assert(source_task.connected_to?("out", sink_task, "out"))
        source_task.connect_ports(sink_task, %w[out other] => { type: :buffer, size: 30 })
        assert_equal(
            {
                %w[out out] => { type: :buffer, size: 20 },
                %w[out other] => { type: :buffer, size: 30 }
            }, source_task[sink_task, Syskit::Flows::DataFlow]
        )
        assert(source_task.connected_to?("out", sink_task, "out"))
        assert(source_task.connected_to?("out", sink_task, "other"))
    end

    def test_connect_ports_non_existent_ports
        source_model = Syskit::TaskContext.new_submodel do
            output_port "out", "/double"
        end
        sink_model = Syskit::TaskContext.new_submodel do
            input_port "out", "/double"
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)

        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task, %w[out does_not_exist] => { type: :buffer, size: 20 })
        end
        assert(!dataflow_graph.has_vertex?(source_task))
        assert(!dataflow_graph.has_vertex?(sink_task))

        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task, %w[does_not_exist out] => { type: :buffer, size: 20 })
        end
        assert(!dataflow_graph.has_vertex?(source_task))
        assert(!dataflow_graph.has_vertex?(sink_task))
        assert(!dataflow_graph.has_vertex?(source_task))
        assert(!dataflow_graph.has_vertex?(sink_task))
    end

    def test_disconnect_ports
        source_model = Syskit::TaskContext.new_submodel do
            output_port "out", "/double"
        end
        sink_model = Syskit::TaskContext.new_submodel do
            input_port "out", "/double"
            input_port "other", "/double"
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        source_task.connect_ports(sink_task, %w[out out] => { type: :buffer, size: 20 })
        source_task.connect_ports(sink_task, %w[out other] => { type: :buffer, size: 30 })
        assert(source_task.connected_to?("out", sink_task, "out"))
        assert(source_task.connected_to?("out", sink_task, "other"))

        source_task.disconnect_ports(sink_task, [%w{out other}])
        assert_equal(
            {
                %w[out out] => { type: :buffer, size: 20 }
            }, source_task[sink_task, Syskit::Flows::DataFlow]
        )
        assert(source_task.connected_to?("out", sink_task, "out"))
        assert(!source_task.connected_to?("out", sink_task, "other"))
    end

    def test_disconnect_ports_non_existent_ports
        source_model = Syskit::TaskContext.new_submodel do
            output_port "out", "/double"
        end
        sink_model = Syskit::TaskContext.new_submodel do
            input_port "out", "/double"
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        source_task.connect_ports(sink_task, %w[out out] => { type: :buffer, size: 20 })

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [%w[out does_not_exist]])
        end
        assert_equal(
            { %w[out out] => { type: :buffer, size: 20 } }, source_task[sink_task, Syskit::Flows::DataFlow]
        )

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [%w[does_not_exist out]])
        end
        assert_equal(
            { %w[out out] => { type: :buffer, size: 20 } }, source_task[sink_task, Syskit::Flows::DataFlow]
        )

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [%w[does_not_exist does_not_exist]])
        end
        assert_equal(
            { %w[out out] => { type: :buffer, size: 20 } }, source_task[sink_task, Syskit::Flows::DataFlow]
        )
    end

    def test_disconnect_ports_non_existent_connection
        source_model = Syskit::TaskContext.new_submodel do
            output_port "out", "/double"
        end
        sink_model = Syskit::TaskContext.new_submodel do
            input_port "out", "/double"
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [%w[out out]])
        end
    end

    def test_merge_merges_explicit_fullfilled_model
        # TODO: make #fullfilled_model= and #fullfilled_model work on the same
        # format (currently, the writer wants [task_model, tags, arguments] and
        # the reader returns [models, arguments]
        model = Syskit::TaskContext.new_submodel name: "Model"
        submodel = model.new_submodel name: "Submodel"

        plan.add(merged_task = model.new(id: "test"))
        merged_task.fullfilled_model = [Syskit::Component, [], { id: "test" }]
        plan.add(merging_task = submodel.new)

        merging_task.merge(merged_task)
        assert_equal([[Syskit::Component], { id: "test" }],
                     merging_task.fullfilled_model)

        plan.add(merged_task = model.new)
        merged_task.fullfilled_model = [Syskit::Component, [], { id: "test" }]
        plan.add(merging_task = submodel.new(id: "test"))
        merging_task.fullfilled_model = [model, [], {}]

        merging_task.merge(merged_task)
        assert_equal([[model], { id: "test" }],
                     merging_task.fullfilled_model)
    end
end
