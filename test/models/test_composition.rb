require 'syskit/test'
require './test/fixtures/simple_composition_model'

# Module used when we want to do some "public" models
module DefinitionModule
end

describe Syskit::Models::Composition do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    def models
        return simple_service_model, simple_component_model, simple_composition_model
    end

    before do
        create_simple_composition_model
    end

    after do
        begin DefinitionModule.send(:remove_const, :Cmp)
        rescue NameError
        end
    end

    it "has a proper name if assigned to a constant" do
        model = Syskit::Composition.new_submodel
        DefinitionModule.const_set :Cmp, model
        assert_equal "DefinitionModule::Cmp", model.name
    end
    
    describe "#new_submodel" do
        it "registers the submodel" do
            submodel = Syskit::Composition.new_submodel
            subsubmodel = submodel.new_submodel

            assert Syskit::Component.submodels.include?(submodel)
            assert Syskit::Component.submodels.include?(subsubmodel)
            assert Syskit::Composition.submodels.include?(submodel)
            assert Syskit::Composition.submodels.include?(subsubmodel)
            assert submodel.submodels.include?(subsubmodel)
        end

        it "does not register the submodels on provided services" do
            submodel = Syskit::Composition.new_submodel
            ds = Syskit::DataService.new_submodel
            submodel.provides ds, :as => 'srv'
            subsubmodel = submodel.new_submodel

            assert !ds.submodels.include?(subsubmodel)
            assert submodel.submodels.include?(subsubmodel)
        end

        it "applies specializations from the parent model to the child model" do
            root = Syskit::Composition.new_submodel { add Syskit::DataService.new_submodel, :as => 'srv' }
            block0 = proc { }
            spec0 = root.specialize(root.srv_child => Syskit::DataService.new_submodel, &block0)
            block1 = proc { }
            spec1 = root.specialize(root.srv_child => Syskit::DataService.new_submodel, &block1)
            submodel = Class.new(root)
            flexmock(Class).should_receive(:new).with(root).and_return(submodel)
            flexmock(submodel).should_receive(:specialize).with(spec0.specialized_children, eq(block0)).once
            flexmock(submodel).should_receive(:specialize).with(spec1.specialized_children, eq(block1)).once
            assert_same submodel, root.new_submodel
        end
    end

    describe "#new_specialized_submodel" do
        it "creates a submodel but does not apply specializations" do
            root = Syskit::Composition.new_submodel { add Syskit::DataService.new_submodel, :as => 'srv' }
            spec0 = root.specialize(root.srv_child => Syskit::DataService.new_submodel)
            spec1 = root.specialize(root.srv_child => Syskit::DataService.new_submodel)
            submodel = Class.new(root)
            flexmock(Class).should_receive(:new).with(root).and_return(submodel)
            flexmock(submodel).should_receive(:specialize).never
            assert_same submodel, root.new_specialized_submodel
        end
    end

    describe "#clear_submodels" do
        it "removes registered submodels" do
            m1 = Syskit::Composition.new_submodel
            m2 = Syskit::Composition.new_submodel
            m11 = m1.new_submodel

            m1.clear_submodels
            assert !m1.submodels.include?(m11)
            assert Syskit::Component.submodels.include?(m1)
            assert Syskit::Composition.submodels.include?(m1)
            assert Syskit::Component.submodels.include?(m2)
            assert Syskit::Composition.submodels.include?(m2)
            assert !Syskit::Component.submodels.include?(m11)
            assert !Syskit::Composition.submodels.include?(m11)

            m11 = m1.new_submodel
            Syskit::Composition.clear_submodels
            assert !m1.submodels.include?(m11)
            assert !Syskit::Component.submodels.include?(m1)
            assert !Syskit::Composition.submodels.include?(m1)
            assert !Syskit::Component.submodels.include?(m2)
            assert !Syskit::Composition.submodels.include?(m2)
            assert !Syskit::Component.submodels.include?(m11)
            assert !Syskit::Composition.submodels.include?(m11)
        end
    end

    describe "#connect" do
        it "can connect ports" do
            component = simple_composition_model
            composition = Syskit::Composition.new_submodel 
            composition.add simple_component_model, :as => 'source'
            composition.add simple_component_model, :as => 'sink'
            composition.connect composition.source_child.out_port => composition.sink_child.in_port
            assert_equal({['source', 'sink'] => {['out', 'in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
        end
    end

    describe "#each_explicit_connection" do
        it "applies port mappings on overloads" do
            service, component, _ = models
            service1 = Syskit::DataService.new_submodel do
                input_port 'specialized_in', '/int'
                output_port 'specialized_out', '/int'
                provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
            end
            component.provides service1, :as => 'srv1'

            base = Syskit::Composition.new_submodel do
                add service, :as => 'srv'
            end

            composition = base.new_submodel
            composition.overload('srv', service1)

            base.add(service, :as => 'srv_in')
            base.connect(base.srv_child => base.srv_in_child)

            assert_equal([[ ['srv', 'srv_in'], {['specialized_out', 'srv_in'] => {}} ]], composition.each_explicit_connection.to_a)
            composition.overload('srv_in', service1)
            assert_equal([[ ['srv', 'srv_in'], {['specialized_out', 'specialized_in'] => {}} ]], composition.each_explicit_connection.to_a)

            composition = composition.new_submodel
            composition.overload('srv', component)
            assert_equal([[ ['srv', 'srv_in'], {['out', 'specialized_in'] => {}} ]], composition.each_explicit_connection.to_a)
            composition.overload('srv_in', component)
            assert_equal([[ ['srv', 'srv_in'], {['out', 'in'] => {}} ]], composition.each_explicit_connection.to_a)
        end
    end

    # Helper method to compare Port objects
    def assert_single_export(expected_name, expected_port, exports)
        exports = exports.to_a
        assert_equal(1, exports.size)
        export_name, exported_port = *exports.first
        assert_equal expected_name, export_name
        assert_equal expected_name, exported_port.name
        assert(exported_port.same_port?(expected_port), "expected #{expected_port} but got #{exported_port}")
    end

    describe "the port export functionality" do
        describe "#export" do
            it "promotes exported input ports by setting the new name and component model but keeps the orogen model" do
                service = Syskit::DataService.new_submodel { input_port 'in', '/int' }
                composition = Syskit::Composition.new_submodel { add service, :as => 'srv' }
                exported_port = composition.export composition.srv_child.in_port, :as => 'srv_in'
                assert_equal Syskit::Models::InputPort.new(composition, composition.srv_child.in_port.orogen_model, 'srv_in'),
                    exported_port
                assert_equal composition.find_port('srv_in'), exported_port
            end
            it "promotes exported output ports by setting the new name and component model but keeps the orogen model" do
                service = Syskit::DataService.new_submodel { output_port 'out', '/int' }
                composition = Syskit::Composition.new_submodel { add service, :as => 'srv' }
                exported_port = composition.export composition.srv_child.out_port, :as => 'srv_out'
                assert_equal Syskit::Models::OutputPort.new(composition, composition.srv_child.out_port.orogen_model, 'srv_out'),
                    exported_port
                assert_equal composition.find_port('srv_out'), exported_port
            end
            # This does not sound quite right, but it is important for
            # specializations. Multiple specializations that can be selected
            # simultaneously sometimes have to export the same port (because
            # they could also be applied separately), which is not an error
            it "allows to export the same port using the same name multiple times" do
                srv_m = Syskit::DataService.new_submodel { input_port 'in', '/int' }
                cmp_m = Syskit::Composition.new_submodel { add srv_m, :as => 'srv' }
                assert cmp_m.srv_child.in_port == cmp_m.srv_child.in_port
                export = cmp_m.export cmp_m.srv_child.in_port,
                    :as => 'srv_in'
                cmp_m.export cmp_m.srv_child.in_port,
                    :as => 'srv_in'
            end
            it "raises if trying to override an existing port export" do
                srv_m = Syskit::DataService.new_submodel { input_port 'in', '/int' }
                cmp_m = Syskit::Composition.new_submodel do
                    add srv_m, :as => 's0'
                    add srv_m, :as => 's1'
                end
                cmp_m.export cmp_m.s0_child.in_port,
                    :as => 'srv_in'
                assert_raises(ArgumentError) do
                    cmp_m.export cmp_m.s1_child.in_port,
                        :as => 'srv_in'
                end
            end
        end

        describe "#find_exported_output" do
            it "returns the actual output port" do
                assert_equal simple_composition_model.srv_child.srv_out_port,
                    simple_composition_model.find_exported_output('srv_out')
            end
            it "returns nil for unknown ports" do
                assert !simple_composition_model.find_exported_output('bla')
            end
        end
        describe "#find_exported_input" do
            it "returns the actual input port" do
                assert_equal simple_composition_model.srv_child.srv_in_port,
                    simple_composition_model.find_exported_input('srv_in')
            end
            it "returns nil for unknown ports" do
                assert !simple_composition_model.find_exported_input('bla')
            end
        end
        describe "#exported_port?" do
            it "allows to test whether a child port is exported with #exported_port?" do
                assert simple_composition_model.exported_port?(simple_composition_model.srv_child.srv_in_port)
                assert !simple_composition_model.exported_port?(simple_composition_model.srv2_child.srv_in_port)
            end
        end
    end

    describe "#find_children_models_and_tasks" do
        it "computes port mappings for selected children" do
            service, component, composition = models
            context = Syskit::DependencyInjectionContext.new('srv' => component)
            explicit, _ = composition.find_children_models_and_tasks(context)
            assert_equal({'srv_in' => 'in', 'srv_out' => 'out'}, explicit['srv'].port_mappings)
        end
    end

    describe "#instanciate" do
        it "applies port mappings from dependency injection on exported ports" do
            service, component, composition = models
            composition = flexmock(composition)
            component = flexmock(component)

            # Make sure the forwarding is set up with the relevant port mapping
            # applied
            component.new_instances.should_receive(:forward_ports).
                with(composition, ['out', 'srv_out']=>{}).
                once
            composition.new_instances.should_receive(:forward_ports).
                with(component, ['srv_in', 'in']=>{}).
                once

            context = Syskit::DependencyInjectionContext.new('srv' => component)
            composition.instanciate(plan, context)
        end

        it "adds its children as dependencies" do
            composition_m = simple_composition_model
            srv_child = simple_component_model.new
            flexmock(simple_component_model).should_receive(:new).
                and_return(srv_child).once
            flexmock(composition_m).new_instances.
                should_receive(:depends_on).by_default.pass_thru
            flexmock(composition_m).new_instances.
                should_receive(:depends_on).with(srv_child, any).once.pass_thru
            composition_m.instanciate(plan, Syskit::DependencyInjectionContext.new('srv' => simple_component_model))
        end

        it "adds its instanciated children with the child name as role" do
            task = simple_composition_model.instanciate(plan)
            child_task = simple_component_model.new
            flexmock(simple_component_model).should_receive(:new).once.and_return(child_task)
            task = simple_composition_model.
                instanciate(plan, Syskit::DependencyInjectionContext.new('srv' => simple_component_model))
            assert task.has_role?('srv'), "no child of task #{task} with role srv, existing roles: #{task.each_role.to_a.sort.join(", ")}"
        end

        it "applies use selections from the child definition" do
            srv = Syskit::DataService.new_submodel(:name => "Srv")
            task = Syskit::TaskContext.new_submodel(:name => "Task") { provides srv, :as => 'srv' }
            cmp = Syskit::Composition.new_submodel(:name => "SubCmp") { add srv, :as => 'srv' }
            root = Syskit::Composition.new_submodel(:name => "Cmp") do
                add cmp, :as => 'cmp'
            end
            root = root.use().instanciate(plan, Syskit::DependencyInjectionContext.new(srv => task))
            assert_same task, root.cmp_child.srv_child.class
        end

        it "augments plain selections with provided informations in the child" do
            srv = Syskit::DataService.new_submodel(:name => "Srv")
            task = Syskit::TaskContext.new_submodel(:name => "Task") { provides srv, :as => 'srv' }
            cmp = Syskit::Composition.new_submodel(:name => "SubCmp") do
                add(srv, :as => 'srv').
                    with_arguments(:test => 10)
            end
            cmp = cmp.instanciate(plan, Syskit::DependencyInjectionContext.new(srv => task))
            assert_same task, cmp.srv_child.class
            assert_equal Hash[:test => 10], cmp.srv_child.arguments
        end

        it "does not pass additional informations from the child if overriden in the selection" do
            srv = Syskit::DataService.new_submodel(:name => "Srv")
            task = Syskit::TaskContext.new_submodel(:name => "Task") { provides srv, :as => 'srv' }
            cmp = Syskit::Composition.new_submodel(:name => "SubCmp") do
                add(srv, :as => 'srv').
                    with_arguments(:test => 10)
            end
            cmp = cmp.instanciate(plan, Syskit::DependencyInjectionContext.new(srv => task.with_arguments(:bla => 20)))
            assert_same task, cmp.srv_child.class
            assert_equal Hash[:bla => 20], cmp.srv_child.arguments
        end

        it "allows to specify selections for granchildren" do
            srv = Syskit::DataService.new_submodel(:name => "Srv")
            task = Syskit::TaskContext.new_submodel(:name => "Task") { provides srv, :as => 'srv' }
            cmp = Syskit::Composition.new_submodel(:name => "SubCmp") { add srv, :as => 'srv' }
            root = Syskit::Composition.new_submodel(:name => "Cmp") do
                add cmp, :as => 'cmp'
            end
            root = root.instanciate(plan, Syskit::DependencyInjectionContext.new('cmp.srv' => task))
            assert_same task, root.cmp_child.srv_child.class
        end

        it "sets the selected requirements on the task instance" do
            srv = Syskit::DataService.new_submodel(:name => "Srv")
            task = Syskit::TaskContext.new_submodel(:name => "Task") { provides srv, :as => 'srv' }
            cmp = Syskit::Composition.new_submodel(:name => "RootCmp") do
                add srv, :as => 'child'
            end

            cmp_task = cmp.instanciate(plan, Syskit::DependencyInjectionContext.new('child' => task))
            assert_equal task.srv_srv, cmp_task.child_child.requirements.service
        end

        it "allows to use grandchildren as use flags for other children" do
            srv = Syskit::DataService.new_submodel(:name => "Srv")
            task = Syskit::TaskContext.new_submodel(:name => "Task") { provides srv, :as => 'srv' }
            first = Syskit::Composition.new_submodel(:name => "FirstCmp") { add srv, :as => 'first_test' }
            second = Syskit::Composition.new_submodel(:name => "SecondCmp") { add srv, :as => 'second_test' }
            cmp = Syskit::Composition.new_submodel(:name => "RootCmp") do
                add first, :as => 'first'
                add(second, :as => 'second').
                    use(srv => first_child.first_test_child)
            end
            root = cmp.instanciate(plan, Syskit::DependencyInjectionContext.new('first.first_test' => task))
            assert_same root.first_child.first_test_child, root.second_child.second_test_child
        end

        it "uses the most narrowed information when passing children as use flags for other children" do
            srv = Syskit::DataService.new_submodel(:name => "Srv")
            task = Syskit::TaskContext.new_submodel(:name => "Task") do
                provides srv, :as => 's0'
                provides srv, :as => 's1'
            end
            first = Syskit::Composition.new_submodel(:name => "FirstCmp") { add srv, :as => 'first_test' }
            second = Syskit::Composition.new_submodel(:name => "SecondCmp") { add srv, :as => 'second_test' }
            cmp = Syskit::Composition.new_submodel(:name => "RootCmp") do
                add first, :as => 'first'
                add(second, :as => 'second').
                    use(srv => first_child.first_test_child)
            end
            root = cmp.instanciate(plan, Syskit::DependencyInjectionContext.new('first.first_test' => task.s0_srv))
            assert_same root.first_child.first_test_child, root.second_child.second_test_child
        end

        it "looks for a specialization using the explicit given selections first and then the default ones" do
            task_m = simple_task_model
            # The value returned by #find_children_models_and_tasks is a
            # name-to-InstanceSelection mapping
            explicit   = Hash['srv' => flexmock(:selected => flexmock(:models => [task_m]))]
            selections = Hash['srv2' => flexmock(:selected => flexmock(:models => [task_m]))]
            cmp_m = simple_composition_model
            subcmp_m = cmp_m.new_submodel(:name => 'Sub')
            final_cmp_m = subcmp_m.new_submodel(:name => 'Final')
            flexmock(cmp_m).should_receive(:find_children_models_and_tasks).and_return([explicit, selections])
            flexmock(cmp_m.specializations, "mng").should_receive(:matching_specialized_model).with('srv' => [task_m]).once.ordered.and_return(subcmp_m)
            flexmock(subcmp_m).should_receive(:find_children_models_and_tasks).and_return([explicit, selections])
            flexmock(subcmp_m.specializations, 'sub_mng').should_receive(:matching_specialized_model).with('srv' => [task_m]).once.ordered.and_return(subcmp_m)
            flexmock(subcmp_m.specializations, 'sub_mng').should_receive(:matching_specialized_model).with('srv2' => [task_m]).once.ordered.and_return(final_cmp_m)
            flexmock(final_cmp_m).should_receive(:find_children_models_and_tasks).and_return([explicit, selections])
            flexmock(final_cmp_m.specializations, 'final_mng').should_receive(:matching_specialized_model).with('srv' => [task_m]).once.ordered.and_return(final_cmp_m)
            flexmock(final_cmp_m.specializations, 'final_mng').should_receive(:matching_specialized_model).with('srv2' => [task_m]).once.ordered.and_return(final_cmp_m)

            flexmock(final_cmp_m).should_receive(:new).and_throw(:pass)
            catch(:pass) do
                cmp_m.instanciate(plan, Syskit::DependencyInjectionContext.new, :task_arguments => Hash[:id => 10])
            end
        end

        it "should not leak DI information from a child to the next" do
            srv_m = Syskit::DataService.new_submodel(:name => 'Srv')
            cmp_m = Syskit::Composition.new_submodel(:name => 'Cmp') do
                add srv_m, :as => 'test1'
                add srv_m, :as => 'test2'
                provides srv_m, :as => 's'
            end
            task1_m = Syskit::TaskContext.new_submodel(:name => 'Task1') { provides srv_m, :as => 'test' }
            task2_m = Syskit::TaskContext.new_submodel(:name => 'Task2') { provides srv_m, :as => 'test' }

            child1_m = cmp_m.to_instance_requirements
            child1_m.dependency_injection_context.push(Syskit::DependencyInjection.new(srv_m => task1_m))
            task = cmp_m.use('test1' => child1_m, 'test2' => cmp_m).
                instanciate(plan, Syskit::DependencyInjectionContext.new(srv_m => task2_m))
            assert_kind_of task1_m, task.test1_child.test1_child
            assert_kind_of task2_m, task.test2_child.test1_child
        end

        describe "dependency relation definition based on information in the child definition" do
            attr_reader :composition_m, :srv_child
            before do
                @srv_child = simple_component_model.new
                flexmock(simple_component_model).should_receive(:new).
                    and_return(srv_child).once
            end
            
            def composition_model(dependency_options)
                m = simple_service_model
                @composition_m = Syskit::Composition.new_submodel do
                    add m, dependency_options.merge(:as => 'srv')
                end
            end
            def instanciate
                @composition = @composition_m.instanciate(plan, Syskit::DependencyInjectionContext.new('srv' => simple_component_model))
            end
            def assert_dependency_contains(flags)
                options = @composition[@srv_child, Roby::TaskStructure::Dependency]
                flags.each do |flag_name, flag_options|
                    actual = options[flag_name]
                    assert_equal flag_options, actual, "#{flag_name} option differs, expected #{flag_options} but got #{actual}"
                end
            end

            it "overrides the :success flag" do
                composition_model :success => [:failed]
                task = instanciate
                assert_dependency_contains :success => :failed.to_unbound_task_predicate
            end
            it "resets the :failure flag if explicitly given the :success flag" do
                composition_model :success => [:failed]
                task = instanciate
                assert_dependency_contains :failure => false.to_unbound_task_predicate
            end
            it "overrides the :failure flag" do
                composition_model :failure => [:success]
                task = instanciate
                assert_dependency_contains :failure => (:start.never.or(:success.to_unbound_task_predicate))
            end
            it "resets the :success flag if explicitly given the :failure flag" do
                composition_model :failure => [:success]
                task = instanciate
                assert_dependency_contains :success => nil
            end
            it "adds additional roles to the default ones" do
                composition_model :roles => ['a_new_role']
                task = instanciate
                assert_dependency_contains :roles => ['a_new_role', 'srv'].to_set
            end
            it "overrides remove_when_done" do
                composition_model :remove_when_done => true
                task = instanciate
                assert_dependency_contains :remove_when_done => true
            end
            it "overrides consider_in_pending" do
                composition_model :consider_in_pending => true
                task = instanciate
                assert_dependency_contains :consider_in_pending => true
            end
            it "uses :failure => [:stop] as default dependency option" do
                composition_model(Hash.new)
                task = instanciate
                assert_dependency_contains :failure => :start.never.or(:stop.to_unbound_task_predicate)
            end
        end
    end

    describe "composition submodels" do
        describe "port mappings" do
            it "is applied on exported ports" do
                service, component, composition = models
                service1 = Syskit::DataService.new_submodel(:name => "Service1") do
                    input_port 'specialized_in', '/int'
                    output_port 'specialized_out', '/int'
                    provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
                end
                component.provides service1, :as => 'srv1'

                c0 = composition.new_submodel(:name => "C0")
                c0.overload('srv', service1)
                assert_single_export 'srv_in', c0.srv_child.specialized_in_port, c0.each_exported_input
                assert_single_export 'srv_out', c0.srv_child.specialized_out_port, c0.each_exported_output

                c1 = c0.new_submodel(:name => "C1")
                c1.overload('srv', component)
                # Re-test for c0 to make sure that the overload did not touch the base
                # model
                assert_single_export 'srv_in', c0.srv_child.specialized_in_port, c0.each_exported_input
                assert_single_export 'srv_out', c0.srv_child.specialized_out_port, c0.each_exported_output
                assert_single_export 'srv_in', c1.srv_child.in_port, c1.each_exported_input
                assert_single_export 'srv_out', c1.srv_child.out_port, c1.each_exported_output
            end
        end

        describe "#add" do
            it "adds new models to an existing set if there is one" do
                srv1 = Syskit::DataService.new_submodel
                srv2 = Syskit::DataService.new_submodel
                cmp = Syskit::Composition.new_submodel do
                    add srv1, :as => 'test'
                end
                assert_equal [srv1].to_set, cmp.test_child.models.to_set
                cmp.overload 'test', srv2
                assert_equal [srv1, srv2].to_set, cmp.test_child.models.to_set
            end
            it "adds new models to the definition of the superclass if there is one" do
                srv1 = Syskit::DataService.new_submodel
                srv2 = Syskit::DataService.new_submodel
                cmp = Syskit::Composition.new_submodel do
                    add srv1, :as => 'test'
                end
                assert_equal [srv1].to_set, cmp.test_child.models.to_set
                cmp = cmp.new_submodel
                cmp.overload 'test', srv2
                assert_equal [srv1, srv2].to_set, cmp.test_child.models.to_set
            end
            it "computes port mappings when overloading a child" do
                service, component, composition = models
                service1 = Syskit::DataService.new_submodel(:name => "Service1") do
                    input_port 'specialized_in', '/int'
                    output_port 'specialized_out', '/int'
                    provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
                end
                component.provides service1, :as => 'srv1'

                c0 = composition.new_submodel(:name => "C0")
                c0.overload('srv', service1)
                child = c0.find_child('srv')
                assert_same composition.find_child('srv'), child.overload_info.required
                assert_equal [service], child.overload_info.required.base_models.to_a
                assert_equal [service1], child.overload_info.selected.base_models.to_a
                assert_equal Hash['srv_in' => 'specialized_in', 'srv_out' => 'specialized_out'],
                    child.port_mappings

                c1 = c0.new_submodel(:name => "C1")
                c1.overload('srv', component)
                child = c1.find_child('srv')
                assert_same c0.find_child('srv'), child.overload_info.required
                assert_equal [service1], child.overload_info.required.base_models.to_a
                assert_equal [component], child.overload_info.selected.base_models.to_a
                assert_equal Hash['specialized_in' => 'in', 'specialized_out' => 'out'],
                    child.port_mappings
            end
        end
    end

    describe "specialized composition models" do
        describe "#each_fullfilled_model" do
            it "should list any additional data services and the root component model but not the specialized model" do
                srv_m = Syskit::DataService.new_submodel
                task_m = Syskit::TaskContext.new_submodel { provides srv_m, :as => 's' }
                cmp_m = Syskit::Composition.new_submodel(:name => 'Cmp') { add srv_m, :as => 'c' }
                cmp_m.specialize cmp_m.c_child => task_m do
                    provides srv_m, :as => 's'
                end
                specialized_m = cmp_m.narrow(Syskit::DependencyInjectionContext.new('c' => task_m))
                
                assert_equal [specialized_m,cmp_m,srv_m,Syskit::DataService,Syskit::Composition,Syskit::Component,Roby::Task].to_set,
                    specialized_m.each_fullfilled_model.to_set
            end
        end
    end

    describe "#find_child" do
        it "promotes child models to the current composition model" do
            srv_m = Syskit::DataService.new_submodel
            parent_m = Syskit::Composition.new_submodel do
                add srv_m, :as => 'child'
            end
            child_m = parent_m.new_submodel
            assert_same child_m, child_m.find_child('child').composition_model
            # Make sure we do not modify parent_m
            assert_same parent_m, parent_m.find_child('child').composition_model
        end
    end

    describe "#specialize" do
        it "converts child objects to names before calling the specialization manager" do
            srv_m = Syskit::DataService.new_submodel
            composition_m = Syskit::Composition.new_submodel do
                add srv_m, :as => 'test'
            end
            sel = flexmock
            flexmock(composition_m.specializations).should_receive(:specialize).once.with('test' => sel)
            composition_m.specialize(composition_m.test_child => sel)
        end

        it "can pass on specializations that are given by name, issuing a warning" do
            composition_m = Syskit::Composition.new_submodel
            sel = flexmock
            flexmock(composition_m.specializations).should_receive(:specialize).once.with('child_name' => sel)
            flexmock(Roby).should_receive(:warn_deprecated)
            composition_m.specialize('child_name' => sel)
        end
    end

    it "should not leak connections from specializations into the root model" do
        shared_task_m = Syskit::TaskContext.new_submodel(:name => "SharedTask") do
            input_port 'input', 'int'
            output_port 'output', 'double'
        end
        generic_srv_m = Syskit::DataService.new_submodel(:name => 'GenericTaskSrv') do
            output_port 'output', 'int'
        end
        special_srv_m = Syskit::DataService.new_submodel(:name => 'SpecialTaskSrv') do
            input_port 'input', 'double'
            provides generic_srv_m
        end

        vision_m = Syskit::Composition.new_submodel do
            add shared_task_m, :as => :shared
            add generic_srv_m, :as => :task
            task_child.connect_to shared_child
        end
        specialized_m = vision_m.specialize vision_m.task_child => special_srv_m do
            shared_child.connect_to task_child
        end
        expected = Hash.new
        expected[['task', 'shared']] = Hash[['output', 'input'] => Hash.new]
        assert_equal expected, vision_m.connections
        expected[['shared', 'task']] = Hash[['output', 'input'] => Hash.new]
        assert_equal expected, specialized_m.composition_model.connections
    end

    describe "#conf" do
        it "registers the child name to conf selection into #configurations" do
            simple_composition_model.conf 'test', \
                simple_composition_model.srv_child => ['default', 'test']
            assert_equal Hash['srv' => ['default', 'test']], simple_composition_model.configurations['test']
        end
        it "accepts to register configurations using strings, but warns about deprecations" do
            flexmock(Roby).should_receive(:warn_deprecated).once
            simple_composition_model.conf 'test', \
                'srv' => ['default', 'test']
            assert_equal Hash['srv' => ['default', 'test']], simple_composition_model.configurations['test']
        end
    end
end

