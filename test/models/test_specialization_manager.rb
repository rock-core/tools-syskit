# frozen_string_literal: true

require "syskit/test/self"
require "minitest/spec"

describe Syskit::Models::SpecializationManager do
    # [Syskit::Models::SpecializationManager] the manager under test
    attr_reader :mng

    attr_reader :cmp_m, :task_m, :srv_m

    before do
        @srv_m = Syskit::DataService.new_submodel
        @task_m = Syskit::TaskContext.new_submodel
        task_m.provides srv_m, as: "test"
        @cmp_m = Syskit::Composition.new_submodel
        cmp_m.add srv_m, as: "test"
        cmp_m.add srv_m, as: "second"
        @mng = cmp_m.specializations
    end

    describe "#each_specialization" do
        it "should create an enumerator if called without a block" do
            enum = mng.each_specialization
            flexmock(mng).should_receive(:each_specialization).with(Proc).once
            enum.each {}
        end

        it "should list the defined specialization objects" do
            flexmock(mng).should_receive(:specializations).and_return("value" => (spec = Object.new))
            yield_mock = flexmock("yield") { |m| m.should_receive(:call).with(spec).once }
            mng.each_specialization do |spec|
                yield_mock.call(spec)
            end
        end
    end

    describe "#normalize_specialization_mappings" do
        it "should not validate if the specialization is valid" do
            mng.normalize_specialization_mappings("non_existent_child" => Syskit::DataService.new_submodel)
        end
        it "should reject invalid selectors" do
            assert_raises(ArgumentError) { mng.normalize_specialization_mappings(Object.new => Syskit::DataService.new_submodel) }
        end
        it "should reject invalid models" do
            assert_raises(ArgumentError) { mng.normalize_specialization_mappings("test" => Object.new) }
        end
        it "should pass thru strings to models" do
            srv = Syskit::DataService.new_submodel
            value = Hash["string" => [srv].to_set]
            assert_equal value, mng.normalize_specialization_mappings(value)
        end
        it "should normalize a single model into a model set" do
            srv = Syskit::DataService.new_submodel
            assert_equal Hash["string" => [srv].to_set],
                         mng.normalize_specialization_mappings("string" => srv)
        end
        it "should convert a component model selector into the corresponding child name" do
            cmp_m.overload("test", task_m)
            c = task_m.new_submodel
            assert_equal Hash["test" => [c].to_set],
                         mng.normalize_specialization_mappings(task_m => c)
        end
        it "should convert a data service selector into the corresponding child name" do
            srv2 = Syskit::DataService.new_submodel
            cmp_m.overload("test", srv2)
            assert_equal Hash["test" => [task_m].to_set],
                         mng.normalize_specialization_mappings(srv2 => task_m)
        end
        it "should raise if a model is used as selector, but there are no corresponding children available" do
            assert_raises(ArgumentError) do
                mng.normalize_specialization_mappings(Syskit::DataService.new_submodel => task_m)
            end
        end
        it "should raise if an ambiguous component model is used as selector" do
            assert_raises(ArgumentError) do
                mng.normalize_specialization_mappings(srv_m => task_m)
            end
        end
    end

    describe "#validate_specialization_mappings" do
        it "should do nothing if the mappings add a new service to a child" do
            srv2 = Syskit::DataService.new_submodel
            mng.validate_specialization_mappings("test" => [srv2])
        end
        it "should do nothing if the mappings update the model of a child" do
            mng.validate_specialization_mappings("test" => [task_m])
        end
        it "should raise if the mappings contain a non-existent child" do
            assert_raises(ArgumentError) do
                mng.validate_specialization_mappings("bla" => [task_m])
            end
        end
        it "should raise if the mappings give a specification for a child, but do not overload it" do
            assert_raises(ArgumentError) do
                mng.validate_specialization_mappings("test" => [srv_m])
            end
        end
        it "should raise if the mappings give a non-compatible specification for a child" do
            cmp_m.overload "test", task_m
            c = Syskit::TaskContext.new_submodel
            assert_raises(Syskit::IncompatibleComponentModels) do
                mng.validate_specialization_mappings("test" => [c])
            end
        end
    end

    describe "#specialize" do
        it "should register a CompositionSpecialization object with normalized and validated mappings" do
            mappings = {}
            normalized_mappings = {}
            flexmock(mng).should_receive(:normalize_specialization_mappings).with(mappings).once.and_return(normalized_mappings)
            flexmock(mng).should_receive(:validate_specialization_mappings).with(normalized_mappings).once.and_return(nil)
            spec = mng.specialize(mappings)
            assert_kind_of Syskit::Models::CompositionSpecialization, spec
            assert_same mng.specializations[normalized_mappings], spec
        end

        it "should register the block on the CompositionSpecialization object" do
            mappings = {}
            normalized_mappings = {}
            flexmock(mng).should_receive(:normalize_specialization_mappings).with(mappings).once.and_return(normalized_mappings)
            flexmock(mng).should_receive(:validate_specialization_mappings).with(normalized_mappings).once.and_return(nil)
            block = proc { add Syskit::TaskContext, as: "child" }
            flexmock(Syskit::Models::CompositionSpecialization).new_instances.should_receive(:add).with(normalized_mappings, eq(block)).once
            mng.specialize(mappings, &block)
        end

        it "should setup compatibilities based on constraint blocks" do
            mng.add_specialization_constraint do |a, b|
                !(a.specialized_children["test"].first <= Syskit::Component && b.specialized_children["test"].first <= Syskit::Component)
            end
            spec0 = mng.specialize "test" => task_m
            spec1 = mng.specialize "test" => cmp_m
            assert !spec0.compatible_with?(spec1)
            assert !spec1.compatible_with?(spec0)
            spec2 = mng.specialize "test" => Syskit::DataService.new_submodel
            assert !spec0.compatible_with?(spec1)
            assert spec0.compatible_with?(spec2)
            assert !spec1.compatible_with?(spec0)
            assert spec1.compatible_with?(spec2)
            assert spec2.compatible_with?(spec0)
            assert spec2.compatible_with?(spec1)
        end

        it "should detect non symmetric compatibility blocks" do
            mng.add_specialization_constraint do |a, b|
                a.specialized_children["test"].first == task_m
            end
            mng.specialize "test" => task_m
            assert_raises(Syskit::NonSymmetricSpecializationConstraint) { mng.specialize "test" => cmp_m }
        end

        it "should validate the given specialization block" do
            assert_raises(NoMethodError) do
                mng.specialize "test" => cmp_m do
                    this_method_does_not_exist
                end
            end
        end

        it "should add the new block to an existing specialization definition if one already exists" do
            spec = mng.specialize "test" => task_m
            new_spec = Syskit::Models::CompositionSpecialization.new
            flexmock(spec).should_receive(:dup).and_return(new_spec)
            my_proc = proc {}
            flexmock(new_spec).should_receive(:add).with(Hash["test" => [task_m].to_set], my_proc).once
            assert_same new_spec, mng.specialize("test" => task_m, &my_proc)
        end

        it "should invalidate the specialized composition models if a block is added to an existing specialization" do
            spec = mng.specialize "test" => task_m
            mng.specialize("test" => task_m)
            refute_same spec.composition_model, mng.specialized_model(spec)
        end

        it "should deregister the created submodel when a specialization is modified" do
            spec = mng.specialize "test" => task_m
            assert(mng.composition_model.each_submodel.to_a.include?(spec.composition_model))
            mng.specialize("test" => task_m)
            assert(!mng.composition_model.each_submodel.to_a.include?(spec.composition_model))
        end

        it "should ensure that #specialized_model does not return the same model than the one created during the definition" do
            spec = mng.specialize "test" => task_m
            refute_same spec.composition_model, mng.specialized_model(spec)
        end
    end

    describe "#specialized_model" do
        # The specialized model that will be given to #specialized_model. We
        # pre-create it so that we can add expectations on it
        #
        # It is already mock'ed
        attr_reader :specialized_model

        before do
            @specialized_model = flexmock(cmp_m.new_submodel)
            flexmock(cmp_m).should_receive(:new_submodel).and_return(@specialized_model)
        end

        it "should return the base composition model if no specializations are selected" do
            assert_same cmp_m,
                        mng.specialized_model(Syskit::Models::CompositionSpecialization.new)
        end

        it "should return the same model for the same specializations" do
            srv2 = Syskit::DataService.new_submodel
            spec = Syskit::Models::CompositionSpecialization.new("test" => [task_m], "second" => [srv2])
            value = mng.specialized_model(spec)
            assert_same value, mng.specialized_model(spec)
        end

        it "should overload the specialized children" do
            srv2 = Syskit::DataService.new_submodel
            specialized_model.should_receive(:overload).with("test", [task_m]).once
            specialized_model.should_receive(:overload).with("second", [srv2]).once
            spec = Syskit::Models::CompositionSpecialization.new("test" => [task_m], "second" => [srv2])
            mng.specialized_model(spec)
        end

        it "should apply the specialization blocks" do
            srv2 = Syskit::DataService.new_submodel
            spec = Syskit::Models::CompositionSpecialization.new("test" => [task_m], "second" => [srv2])
            recorder = flexmock
            blocks = (1..2).map do
                proc { recorder.called(object_id) }
            end
            spec.add({}, blocks)

            recorder.should_receive(:called).with(specialized_model.object_id).twice
            mng.specialized_model(spec)
        end

        it "should register the compatible specializations in the new model's specialization manager" do
            srv2 = Syskit::DataService.new_submodel
            spec0 = Syskit::Models::CompositionSpecialization.new("second" => [srv2])
            spec1 = Syskit::Models::CompositionSpecialization.new("test" => [task_m])

            flexmock(Syskit::Models::SpecializationManager).new_instances.should_receive(:register).with(spec1).once
            spec0.compatibilities << spec1
            spec1.compatibilities << spec0
            mng.specialized_model(spec0)
        end

        it "should register the specializations in #applied_specializations" do
            srv2 = Syskit::DataService.new_submodel
            spec0 = Syskit::Models::CompositionSpecialization.new("second" => [srv2])
            spec1 = Syskit::Models::CompositionSpecialization.new("test" => [task_m])
            model = mng.specialized_model(spec0.merge(spec1), [spec0, spec1])
            assert_equal model.applied_specializations, [spec0, spec1].to_set
        end
    end

    describe "#partition_specializations" do
        attr_reader :spec0
        attr_reader :spec1
        attr_reader :spec2

        before do
            @spec0 = Syskit::Models::CompositionSpecialization.new("second" => [task_m])
            @spec1 = Syskit::Models::CompositionSpecialization.new("test" => [task_m])
            @spec2 = Syskit::Models::CompositionSpecialization.new("test" => [cmp_m])
            spec0.compatibilities << spec1 << spec2
            spec1.compatibilities << spec0
            spec2.compatibilities << spec0
        end

        it "should return empty if given no specializations to partition" do
            assert_equal [], mng.partition_specializations([])
        end

        it "should only partition the listed arguments and not all the ones in the compatibility list" do
            # This verifies that, even if more specializations are listed in the
            # compatibility lists, only the ones given as arguments are
            # considered
            flexmock(Syskit::Models::CompositionSpecialization).new_instances.should_receive(:merge).with(spec0).once
            assert_equal [[spec0].to_set], mng.partition_specializations([spec0]).map(&:last)
        end

        it "should return a single element if given two compatible elements" do
            specialization_instances = flexmock(Syskit::Models::CompositionSpecialization).new_instances
            specialization_instances.should_receive(:merge).with(spec0).once
            specialization_instances.should_receive(:merge).with(spec1).once
            value = mng.partition_specializations([spec0, spec1]).map(&:last)
            assert_equal [[spec0, spec1].to_set], value
        end

        it "should create two subsets if given two incompatible elements" do
            result = mng.partition_specializations([spec0, spec1, spec2]).map(&:last)
            assert_equal [[spec0, spec1].to_set, [spec0, spec2].to_set].to_set, result.to_set
        end
    end

    describe "#find_matching_specializations" do
        attr_reader :spec0, :spec1, :spec2
        before do
            @spec0 = mng.specialize "test" => task_m
            @spec1 = mng.specialize "test" => cmp_m
            @spec2 = mng.specialize "second" => task_m
        end

        it "should return the non-specialized model if it has no specializations" do
            mng.specializations.clear
            result = mng.find_matching_specializations("test" => task_m)
            assert_equal 1, result.size
            assert result[0][0].specialized_children.empty?
            assert_equal [], result[0][1]
        end
        it "should return the non-specialized model if it is given an empty selection" do
            result = mng.find_matching_specializations({})
            assert_equal 1, result.size
            assert result[0][0].specialized_children.empty?
            assert_equal [], result[0][1]
        end
        it "should return the non-specialized model if it is given a selection that does not match a specialization" do
            result = mng.find_matching_specializations("test" => Syskit::TaskContext.new_submodel)
            assert_equal 1, result.size
            assert result[0][0].specialized_children.empty?
            assert_equal [], result[0][1]
        end

        it "should return the partitioned specializations that match the selection weakly" do
            selection = { "test" => task_m }
            flexmock(spec0).should_receive(:weak_match?).with(selection).and_return(true)
            flexmock(spec1).should_receive(:weak_match?).with(selection).and_return(true)
            flexmock(spec2).should_receive(:weak_match?).with(selection).and_return(false)
            flexmock(mng).should_receive(:partition_specializations).with([spec0, spec1]).and_return(obj = Object.new)
            assert_equal obj, mng.find_matching_specializations(selection)
        end
    end

    describe "#matching_specialized_model" do
        it "returns the composition model if no specialization matches" do
            selection = {}
            flexmock(mng).should_receive(:find_matching_specializations).with(selection).and_return([])
            assert_equal cmp_m, mng.matching_specialized_model(selection)
        end
        it "returns the composition model for a single match" do
            selection = {}
            match = [flexmock, [flexmock]]
            flexmock(mng).should_receive(:find_matching_specializations).with(selection).and_return([match])
            flexmock(mng).should_receive(:specialized_model).once
                         .with(match[0], match[1]).and_return(model = flexmock)
            assert_equal model, mng.matching_specialized_model(selection)
        end
        it "raises if more than one specialization matches and strict is set" do
            selection = Hash["child" => task_m.selected_for(srv_m)]
            flexmock(mng).should_receive(:find_matching_specializations)
                         .with("child" => task_m)
                         .and_return([[flexmock(:weak_match? => true), []], [flexmock(:weak_match? => true), []]])
            assert_raises(Syskit::AmbiguousSpecialization) do
                mng.matching_specialized_model(selection, strict: true)
            end
        end
        it "uses the common subset if more than one specialization matches and strict is not set" do
            selection = {}
            matches = [[flexmock(:weak_match? => true), [flexmock]], [flexmock(:weak_match? => true), [flexmock]]]
            flexmock(mng).should_receive(:find_matching_specializations).with(selection).and_return(matches)
            flexmock(mng).should_receive(:find_common_specialization_subset).once
                         .with(matches).and_return(matches[0])
            flexmock(mng).should_receive(:specialized_model).once
                         .with(matches[0][0], matches[0][1]).and_return(model = flexmock)
            assert_equal model, mng.matching_specialized_model(selection, strict: false)
        end
        it "applies specializations that are orthogonal from the service selection" do
            task_spec = cmp_m.specialize cmp_m.test_child => task_m
            selection, = Syskit::DependencyInjection.new("test" => task_m)
                                                    .instance_selection_for("test", cmp_m.test_child)
            selection = Hash["test" => selection]
            result = cmp_m.specializations
                          .matching_specialized_model(selection, strict: true)
            assert result.applied_specializations.include?(task_spec)
        end
        it "can disambiguate among the possible specializations based on the selected services" do
            selection = Hash["test" => task_m.test_srv.selected_for(cmp_m.test_child)]
            matches = [[a = flexmock, [flexmock]], [b = flexmock, [flexmock]]]
            a.should_receive(:weak_match?).with(selection).and_return(true)
            b.should_receive(:weak_match?).with(selection).and_return(false)
            flexmock(mng).should_receive(:find_matching_specializations).with("test" => task_m).and_return(matches)
            flexmock(mng).should_receive(:specialized_model).once
                         .with(matches[0][0], matches[0][1]).and_return(model = flexmock)
            assert_equal model, mng.matching_specialized_model(selection, strict: true)
        end
        it "can disambiguate among the possible specializations based on the specialization hints" do
            selection = flexmock
            selection.should_receive(:transform_values).and_return(selection)
            matches = [[a = flexmock, [flexmock]], [b = flexmock, [flexmock]]]
            hint = flexmock
            a.should_receive(:weak_match?).with(hint).and_return(true)
            b.should_receive(:weak_match?).with(hint).and_return(false)
            flexmock(mng).should_receive(:find_matching_specializations).with(selection).and_return(matches)
            flexmock(mng).should_receive(:specialized_model).once
                         .with(matches[0][0], matches[0][1]).and_return(model = flexmock)
            assert_equal model, mng.matching_specialized_model(
                selection, strict: true,
                           specialization_hints: [hint]
            )
        end
    end

    describe "#find_common_specialization_subset" do
        it "should create the specialization specification for the common specializations" do
            candidates = [
                [flexmock, [a = flexmock, b = flexmock, c = flexmock]],
                [flexmock, [a, b, d = flexmock]]
            ]
            spec = flexmock(Syskit::Models::CompositionSpecialization.new)
            flexmock(Syskit::Models::CompositionSpecialization).should_receive(:new).and_return(spec)
            spec.should_receive(:merge).with(a).and_return(spec)
            spec.should_receive(:merge).with(b).and_return(spec)
            assert_equal [spec, [a, b].to_set], mng.find_common_specialization_subset(candidates)
        end
    end

    describe "#create_specialized_model" do
        it "should only inherit compatible specializations from the root" do
            root = Syskit::Composition.new_submodel(name: "Cmp") { add Syskit::DataService.new_submodel, as: "test" }
            spec0 = root.specialize(root.test_child => (srv0 = Syskit::DataService.new_submodel))
            spec1 = root.specialize(root.test_child => (srv1 = Syskit::DataService.new_submodel))
            spec2 = root.specialize(root.test_child => (srv2 = Syskit::DataService.new_submodel))
            flexmock(spec2).should_receive(:compatibilities).and_return([spec1])
            m = root.specializations.create_specialized_model(spec2, [spec2])
            assert_equal [spec1], m.specializations.each_specialization.to_a
        end

        def create_complex_specialization
            # What we do here is create a specialization that assumes that the
            # child is of the service given for specialization, and then apply
            # it on a subclass of the root in which the child is a task that
            # requires some port mappings. The port mapping should be properly
            # applied
            base_srv_m = Syskit::DataService.new_submodel
            srv_m = Syskit::DataService.new_submodel do
                output_port "srv_out", "/double"
                provides base_srv_m
            end
            task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
                provides srv_m, as: "test"
            end

            root_m = Syskit::Composition.new_submodel do
                add base_srv_m, as: "test"
            end
            [root_m, task_m, srv_m]
        end

        it "should give a child that responds to #child_name" do
            child = nil
            root_m, task_m, srv_m = create_complex_specialization
            root_m.specialize root_m.test_child => srv_m do
                child = test_child.child_name
            end
            assert_equal "test", child
        end
        it "should apply the block within a context where the children are typed appropriately" do
            root_m, task_m, srv_m = create_complex_specialization
            root_m.specialize root_m.test_child => srv_m do
                export test_child.srv_out_port
            end
            child_m = root_m.new_submodel
            child_m.overload "test", task_m
            child_m.instanciate(plan)
        end
    end
end
