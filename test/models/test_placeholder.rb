# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Models
        describe Placeholder::Creation do
            describe "resolve_models_argument" do
                attr_reader :task_m, :srv_m

                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    @srv_m  = Syskit::DataService.new_submodel
                end

                describe "calling without an explicit component model" do
                    it "separates a task model and data services" do
                        assert_equal [task_m, [srv_m], nil],
                                     Placeholder.resolve_models_argument([srv_m, task_m])
                    end
                    it "returns Syskit::Component as task model if none is given" do
                        assert_equal [Syskit::Component, [srv_m], nil],
                                     Placeholder.resolve_models_argument([srv_m])
                    end
                    it "uses a bound data service task model as component model" do
                        task_m.provides srv_m, as: "test"
                        other_srv_m = Syskit::DataService.new_submodel
                        assert_equal [task_m, [other_srv_m], task_m.test_srv],
                                     Placeholder.resolve_models_argument([task_m.test_srv, other_srv_m])
                    end
                    it "removes already fullfilled models from the service list" do
                        task_m.provides srv_m, as: "test"
                        assert_equal [task_m, [], nil],
                                     Placeholder.resolve_models_argument([task_m, srv_m])
                    end

                    it "raises ArgumentError if more than one task model was given" do
                        other_task_m = Syskit::Component.new_submodel
                        assert_raises(ArgumentError) do
                            Placeholder.resolve_models_argument([task_m, other_task_m])
                        end
                    end
                    it "raises ArgumentError if a task model and a bound data service were given" do
                        task_m.provides srv_m, as: "test"
                        other_task_m = Syskit::Component.new_submodel
                        assert_raises(ArgumentError) do
                            Placeholder.resolve_models_argument([other_task_m, task_m.test_srv])
                        end
                    end
                    it "raises ArgumentError if more than one bound data service were given" do
                        task_m.provides srv_m, as: "test"
                        task_m.provides srv_m, as: "other"
                        assert_raises(ArgumentError) do
                            Placeholder.resolve_models_argument([task_m.other_srv, task_m.test_srv])
                        end
                    end
                end
                describe "called with an explicit component model" do
                    it "handles a bound data service as component model" do
                        other_srv_m = Syskit::DataService.new_submodel
                        task_m.provides other_srv_m, as: "test"
                        assert_equal [task_m, [srv_m], task_m.test_srv],
                                     Placeholder.resolve_models_argument([srv_m], component_model: task_m.test_srv)
                    end
                    it "filters out already provided services" do
                        task_m.provides srv_m, as: "test"
                        assert_equal [task_m, [], nil],
                                     Placeholder.resolve_models_argument([srv_m], component_model: task_m)
                    end
                    it "handles a plain component model" do
                        assert_equal [task_m, [srv_m], nil],
                                     Placeholder.resolve_models_argument([srv_m], component_model: task_m)
                    end
                end
            end

            describe "create_for" do
                attr_reader :srv0_m, :srv1_m, :service_models, :component_model, :task_m
                before do
                    @service_models = flexmock
                    @component_model = flexmock
                    @task_m = Syskit::TaskContext.new_submodel(name: "T")
                    @srv0_m = Syskit::DataService.new_submodel(name: "A")
                    @srv1_m = Syskit::DataService.new_submodel(name: "B")
                    flexmock(Placeholder).should_receive(:resolve_models_argument)
                                         .once
                                         .with(service_models, component_model: component_model)
                                         .and_return([task_m, [srv0_m, srv1_m], nil])
                end
                it "creates an abstract model that is its own concrete model" do
                    placeholder_m = Placeholder.create_for(service_models,
                                                           component_model: component_model)
                    assert placeholder_m.abstract?
                    assert_same placeholder_m, placeholder_m.concrete_model
                    assert placeholder_m.placeholder?
                end
                it "registers the created placeholder model as a submodel "\
                    "of the component model" do
                    placeholder_m = Placeholder.create_for(service_models,
                                                           component_model: component_model)
                    assert task_m.has_submodel?(placeholder_m)
                end
                it "creates a model that fullfills the given arguments" do
                    placeholder_m = Placeholder.create_for(service_models,
                                                           component_model: component_model)
                    expected_models = [task_m, srv0_m, srv1_m]
                                      .map { |m| m.each_fullfilled_model.to_set }
                                      .inject(&:|)

                    assert_equal expected_models,
                                 placeholder_m.each_fullfilled_model.to_set
                end
                it "ensures that the created model provides all specified services" do
                    placeholder_m = Placeholder.create_for(service_models,
                                                           component_model: component_model)
                    assert_equal srv0_m, placeholder_m.m0_srv.model
                    assert_equal srv1_m, placeholder_m.m1_srv.model
                end
                it "sets a default name" do
                    placeholder_m = Placeholder.create_for(service_models,
                                                           component_model: component_model)
                    assert_equal "Syskit::Models::Placeholder<T,A,B>", placeholder_m.name
                end
                it "uses the 'as' argument as the created service name if provided" do
                    placeholder_m = Placeholder.create_for(service_models,
                                                           component_model: component_model, as: "Name")
                    assert_equal "Name", placeholder_m.name
                end
            end

            describe "for" do
                attr_reader :srv0_m, :srv1_m, :service_models, :task_m
                before do
                    @task_m = Syskit::TaskContext.new_submodel(name: "T")
                    @srv0_m = Syskit::DataService.new_submodel(name: "A")
                    @srv1_m = Syskit::DataService.new_submodel(name: "B")
                    @service_models = Set[srv0_m, srv1_m]
                end
                describe "placeholder model creation" do
                    attr_reader :placeholder_m, :placeholder_name
                    before do
                        @placeholder_m = task_m.new_submodel
                        @placeholder_name = flexmock
                        flexmock(Placeholder).should_receive(:create_for)
                                             .with(service_models, component_model: task_m, as: placeholder_name)
                                             .and_return(placeholder_m)
                    end
                    it "creates a placeholder model and returns it" do
                        flexmock(Placeholder).should_receive(:resolve_models_argument)
                                             .with(service_models, component_model: task_m)
                                             .and_return([task_m, service_models, nil])
                        assert_equal placeholder_m, Placeholder.for(
                            service_models, component_model: task_m, as: placeholder_name
                        )
                    end
                    it "bounds a provided data service to the created placeholder model" do
                        task_m.provides srv0_m, as: "test"
                        flexmock(Placeholder).should_receive(:resolve_models_argument)
                                             .with(service_models, component_model: task_m.test_srv)
                                             .and_return([task_m, service_models, task_m.test_srv])
                        assert_equal placeholder_m.test_srv, Placeholder.for(
                            service_models, component_model: task_m.test_srv, as: placeholder_name
                        )
                    end
                end
                it "returns the same placeholder model if called more than once" do
                    placeholder_m = Placeholder.for([task_m, srv0_m])
                    assert_same placeholder_m, Placeholder.for([task_m, srv0_m])
                end
                it "returns a new placeholder model after #clear_submodels has been called" do
                    placeholder_m = Placeholder.for([task_m, srv0_m])
                    task_m.clear_submodels
                    refute_same placeholder_m, Placeholder.for([task_m, srv0_m])
                end
                it "returns the component model if no extra data services were specified" do
                    assert_same task_m, Placeholder.for([task_m])
                end
                it "returns the bound data service if no extra data services were specified" do
                    task_m.provides srv0_m, as: "test"
                    assert_equal task_m.test_srv, Placeholder.for([task_m.test_srv])
                end
            end

            describe "specialized placeholder types" do
                attr_reader :srv0_m, :srv1_m, :task_m
                before do
                    @task_m = Syskit::TaskContext.new_submodel(name: "T")
                    @srv0_m = Syskit::DataService.new_submodel(name: "A")
                    @srv1_m = Syskit::DataService.new_submodel(name: "B")
                end
                it "provides the same creation API than Placeholder" do
                    placeholder_type = Placeholder.new_specialized_placeholder
                    placeholder_m = placeholder_type.create_for([srv0_m], component_model: task_m)
                    assert(placeholder_m.kind_of?(placeholder_type))
                end
                it "does not interfere with cached values from other placeholder types" do
                    placeholder_type = Placeholder.new_specialized_placeholder
                    placeholder_m = placeholder_type.for([srv0_m], component_model: task_m)
                    refute_same placeholder_m, Placeholder.for([srv0_m], component_model: task_m)
                end
                it "allows to extend the model API" do
                    placeholder_type = Placeholder.new_specialized_placeholder do
                        def specialized_placeholder?
                            true
                        end
                    end
                    placeholder_m = placeholder_type.create_for([srv0_m, task_m])
                    assert placeholder_m.specialized_placeholder?
                end
                it "allows to extend the task API" do
                    task_extension = Module.new do
                        def specialized_placeholder?
                            true
                        end
                    end
                    placeholder_type = Placeholder.new_specialized_placeholder(task_extension: task_extension)
                    placeholder_m = placeholder_type.create_for([srv0_m, task_m])
                    assert placeholder_m.new.specialized_placeholder?
                end
            end
        end

        describe Placeholder do
            describe "pure proxies of data services" do
                before do
                    @srv_m = Syskit::DataService.new_submodel do
                        output_port "out_p", "/int32_t"
                    end
                end

                it "lists AbstractComponent as fullfilled model" do
                    srv_m = DataService.new_submodel
                    proxy_m = Placeholder.create_for([srv_m])
                    assert proxy_m.each_fullfilled_model.to_a
                                  .include?(AbstractComponent)
                end
                it "can be found through AbstractComponent" do
                    srv_m = DataService.new_submodel
                    proxy_m = Placeholder.create_for([srv_m])
                    plan.add(task = proxy_m.new)
                    assert_equal [task], plan.find_local_tasks(AbstractComponent).to_a
                end
                it "only fullfills the service models" do
                    proxy_m = Placeholder.create_for([@srv_m])
                    assert_equal [@srv_m, Syskit::DataService, Syskit::AbstractComponent],
                                 proxy_m.each_fullfilled_model.to_a
                end
                it "creates a task model that represents a data service" do
                    proxy_m = Placeholder.create_for([@srv_m])
                    assert_equal Syskit::Component, proxy_m.supermodel
                    assert proxy_m.find_data_service_from_type(@srv_m)
                end
                describe "the proxy model" do
                    before do
                        @proxy_m = Placeholder.create_for([@srv_m])
                    end
                    it "does not respond to an unknown port" do
                        refute @proxy_m.respond_to?(:not_a_port)
                    end
                    it "responds to a known port" do
                        assert @proxy_m.respond_to?(:out_p_port)
                    end
                end
            end

            describe "proxies based on task models" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    @srv_m = Syskit::DataService.new_submodel do
                        output_port "out_p", "/int32_t"
                    end
                end

                it "creates a task model that represents a data service" do
                    proxy_m = Placeholder.create_for([@task_m, @srv_m])
                    assert_equal @task_m, proxy_m.supermodel
                    assert proxy_m.find_data_service_from_type(@srv_m)
                end
                describe "the proxy model" do
                    before do
                        @proxy_m = Placeholder.create_for([@task_m, @srv_m])
                    end
                    it "does not respond to an unknown port" do
                        refute @proxy_m.respond_to?(:not_a_port)
                    end
                    it "responds to a known port" do
                        assert @proxy_m.respond_to?(:out_p_port)
                    end
                end
            end

            describe "#merge" do
                attr_reader :srv0_m, :srv1_m, :task_m
                before do
                    @task_m = Syskit::TaskContext.new_submodel(name: "T")
                    @srv0_m = Syskit::DataService.new_submodel(name: "A")
                    @srv1_m = Syskit::DataService.new_submodel(name: "B")
                end

                it "returns a new placeholder model that provides the combined models" do
                    self_m  = Placeholder.for([srv0_m], component_model: task_m)
                    other_m = Placeholder.for([srv1_m], component_model: task_m)
                    flexmock(Placeholder).should_receive(:for).with(Set[srv0_m, srv1_m], component_model: task_m)
                                         .once.and_return(result_m = flexmock)
                    assert_equal result_m, self_m.merge(other_m)
                end
                it "dispatches to a bound data service if it is given one" do
                    srv2_m = Syskit::DataService.new_submodel
                    task_m.provides srv2_m, as: "test"
                    self_m = Placeholder.for([srv0_m], component_model: task_m)
                    other_m = Placeholder.for([srv1_m], component_model: task_m)
                    result_m = self_m.merge(other_m.test_srv)
                    assert_equal Set[srv0_m, srv1_m], result_m.component_model.proxied_data_service_models.to_set
                    assert_equal task_m, result_m.component_model.proxied_component_model
                    assert_equal result_m.component_model.test_srv, result_m
                end
                it "returns self if it provides everything" do
                    subtask_m = task_m.new_submodel
                    srv0_m.provides srv1_m
                    self_m = Placeholder.for([srv0_m], component_model: subtask_m)
                    other_m = Placeholder.for([srv1_m], component_model: task_m)
                    assert_equal self_m, self_m.merge(other_m)
                end
                it "returns its argument if it provides everything" do
                    subtask_m = task_m.new_submodel
                    self_m = Placeholder.for([srv0_m], component_model: task_m)
                    other_m = Placeholder.for([srv0_m, srv1_m], component_model: subtask_m)
                    assert_equal other_m, self_m.merge(other_m)
                end
                it "handles arguments that are not placeholder models themselves" do
                    self_m  = Placeholder.for([srv0_m], component_model: task_m)
                    other_m = task_m.new_submodel
                    flexmock(Placeholder).should_receive(:for).with(Set[srv0_m], component_model: other_m)
                                         .once.and_return(result_m = flexmock)
                    assert_equal result_m, self_m.merge(other_m)
                end
                it "merges the placeholder's base task models together" do
                    other_task_m = Syskit::Component.new_submodel
                    self_m = Placeholder.for([srv0_m], component_model: task_m)
                    other_m = Placeholder.for([srv1_m], component_model: other_task_m)
                    flexmock(task_m).should_receive(:merge).with(other_task_m)
                                    .and_return(merged_task_m = task_m.new_submodel)
                    flexmock(Placeholder).should_receive(:for)
                                         .with(Set[srv0_m, srv1_m], component_model: merged_task_m)
                                         .once.and_return(result_m = flexmock)
                    assert_equal result_m, self_m.merge(other_m)
                end
                it "merges the placeholder's base task model with a plain task model" do
                    self_m  = Placeholder.for([srv0_m], component_model: task_m)
                    other_m = Syskit::Component.new_submodel
                    flexmock(task_m).should_receive(:merge).with(other_m)
                                    .and_return(merged_task_m = task_m.new_submodel)
                    flexmock(Placeholder).should_receive(:for)
                                         .with(Set[srv0_m], component_model: merged_task_m)
                                         .once.and_return(result_m = flexmock)
                    assert_equal result_m, self_m.merge(other_m)
                end
            end
        end

        describe "#create_proxy_task_model_for" do
            before do
                @srv_m = Syskit::DataService.new_submodel do
                    output_port "out_p", "/double"
                end
            end
        end

        describe "#can_merge?" do
            describe "handling of dynamic services" do
                attr_reader :srv0, :srv1, :task_m
                before do
                    base_srv = Syskit::DataService.new_submodel
                    @srv0 = base_srv.new_submodel
                    @srv1 = base_srv.new_submodel
                    @task_m = Syskit::TaskContext.new_submodel do
                        dynamic_service base_srv, as: "test" do
                            provides options[:srv]
                        end
                    end
                end

                it "returns false if there are mismatching dynamic services" do
                    task0_m = task_m.specialize
                    task0_m.require_dynamic_service "test", srv: srv0, as: "srv"
                    task1_m = task_m.specialize
                    task1_m.require_dynamic_service "test", srv: srv1, as: "srv"
                    refute task0_m.can_merge?(task1_m)
                end
                it "handles multiple levels of specialization" do
                    task0_m = task_m.specialize
                    task0_m.require_dynamic_service "test", srv: srv0, as: "srv"
                    task1_m = task_m.specialize
                    task1_m.require_dynamic_service "test", srv: srv1, as: "srv"
                    refute task0_m.specialize.can_merge?(task1_m)
                end

                it "returns false if two dynamic services have the same type but different options" do
                    task0_m = task_m.specialize
                    task0_m.require_dynamic_service "test", srv: srv0, as: "srv", port_name: "test"
                    task1_m = task_m.specialize
                    task1_m.require_dynamic_service "test", srv: srv0, as: "srv", port_name: "test2"
                    refute task0_m.can_merge?(task1_m)
                end
            end
        end

        describe "PlaceholderTask" do
            it "autoloads and emits a deprecation warning" do
                deprecated_feature do
                    assert_same Placeholder, PlaceholderTask
                end
            end
        end
    end
end
