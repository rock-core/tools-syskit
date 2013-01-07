require 'syskit/test'
require './test/fixtures/simple_composition_model'
require 'minitest/spec'

describe Syskit::Models::SpecializationManager do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    # [Syskit::Models::SpecializationManager] the manager under test
    attr_reader :mng

    before do
        create_simple_composition_model
        @mng = Syskit::Models::SpecializationManager.new(simple_composition_model)
    end

    describe "#each_specialization" do
        it "should create an enumerator if called without a block" do
            enum = mng.each_specialization
            flexmock(mng).should_receive(:each_specialization).with(Proc).once
            enum.each { }
        end

        it "should list the defined specialization objects" do
            flexmock(mng).should_receive(:specializations).and_return('value' => (spec = Object.new))
            yield_mock = flexmock('yield') { |m| m.should_receive(:call).with(spec).once }
            mng.each_specialization do |spec|
                yield_mock.call(spec)
            end
        end
    end

    describe "#normalize_specialization_mappings" do
        it "should not validate if the specialization is valid" do
            mng.normalize_specialization_mappings('non_existent_child' => Syskit::DataService.new_submodel)
        end
        it "should reject invalid selectors" do
            assert_raises(ArgumentError) { mng.normalize_specialization_mappings(Object.new => Syskit::DataService.new_submodel) }
        end
        it "should reject invalid models" do
            assert_raises(ArgumentError) { mng.normalize_specialization_mappings('srv' => Object.new) }
        end
        it "should pass thru strings to models" do
            srv = Syskit::DataService.new_submodel
            value = Hash['string' => [srv].to_set]
            assert_equal value, mng.normalize_specialization_mappings(value)
        end
        it "should normalize a single model into a model set" do
            srv = Syskit::DataService.new_submodel
            assert_equal Hash['string' => [srv].to_set],
                mng.normalize_specialization_mappings('string' => srv)
        end
        it "should convert a component model selector into the corresponding child name" do
            simple_composition_model.overload('srv', simple_component_model)
            c = simple_component_model.new_submodel
            assert_equal Hash['srv' => [c].to_set],
                mng.normalize_specialization_mappings(simple_component_model => c)
        end
        it "should convert a data service selector into the corresponding child name" do
            srv2 = Syskit::DataService.new_submodel
            simple_composition_model.overload('srv', srv2)
            assert_equal Hash['srv' => [simple_component_model].to_set],
                mng.normalize_specialization_mappings(srv2 => simple_component_model)
        end
        it "should raise if a model is used as selector, but there are no corresponding children available" do
            assert_raises(ArgumentError) do
                mng.normalize_specialization_mappings(Syskit::DataService.new_submodel => simple_component_model)
            end
        end
        it "should raise if an ambiguous component model is used as selector" do
            assert_raises(ArgumentError) do
                mng.normalize_specialization_mappings(simple_service_model => simple_component_model)
            end
        end
    end

    describe "#validate_specialization_mappings" do
        it "should do nothing if the mappings add a new service to a child" do
            srv2 = Syskit::DataService.new_submodel
            mng.validate_specialization_mappings('srv' => [srv2])
        end
        it "should do nothing if the mappings update the model of a child" do
            mng.validate_specialization_mappings('srv' => [simple_component_model])
        end
        it "should raise if the mappings contain a non-existent child" do
            assert_raises(ArgumentError) do
                mng.validate_specialization_mappings('bla' => [simple_component_model])
            end
        end
        it "should raise if the mappings give a specification for a child, but do not overload it" do
            assert_raises(ArgumentError) do
                mng.validate_specialization_mappings('srv' => [simple_service_model])
            end
        end
        it "should raise if the mappings give a non-compatible specification for a child" do
            simple_composition_model.overload 'srv', simple_component_model
            c = Syskit::TaskContext.new_submodel
            assert_raises(Syskit::IncompatibleComponentModels) do
                mng.validate_specialization_mappings('srv' => [c])
            end
        end
    end

    describe "#specialize" do
        it "should register a CompositionSpecialization object with normalized and validated mappings" do
            mappings = Hash.new
            normalized_mappings = Hash.new
            flexmock(mng).should_receive(:normalize_specialization_mappings).with(mappings).once.and_return(normalized_mappings)
            flexmock(mng).should_receive(:validate_specialization_mappings).with(normalized_mappings).once.and_return(nil)
            spec = mng.specialize(mappings)
            assert_kind_of Syskit::Models::CompositionSpecialization, spec
            assert_same mng.specializations[normalized_mappings], spec
        end

        it "should register the block on the CompositionSpecialization object" do
            mappings = Hash.new
            normalized_mappings = Hash.new
            flexmock(mng).should_receive(:normalize_specialization_mappings).with(mappings).once.and_return(normalized_mappings)
            flexmock(mng).should_receive(:validate_specialization_mappings).with(normalized_mappings).once.and_return(nil)
            block = proc { add Syskit::TaskContext, :as => 'child' }
            flexmock(Syskit::Models::CompositionSpecialization).new_instances.should_receive(:add).with(normalized_mappings, eq(block)).once
            mng.specialize(mappings, &block)
        end

        it "should setup compatibilities based on constraint blocks" do
            mng.add_specialization_constraint do |a, b|
                !(a.specialized_children['srv'].first <= Syskit::Component && b.specialized_children['srv'].first <= Syskit::Component)
            end
            spec0 = mng.specialize 'srv' => simple_component_model
            spec1 = mng.specialize 'srv' => simple_composition_model
            assert !spec0.compatible_with?(spec1)
            assert !spec1.compatible_with?(spec0)
            spec2 = mng.specialize 'srv' => Syskit::DataService.new_submodel
            assert !spec0.compatible_with?(spec1)
            assert spec0.compatible_with?(spec2)
            assert !spec1.compatible_with?(spec0)
            assert spec1.compatible_with?(spec2)
            assert spec2.compatible_with?(spec0)
            assert spec2.compatible_with?(spec1)
        end

        it "should detect non symmetric compatibility blocks" do
            mng.add_specialization_constraint do |a, b|
                a.specialized_children['srv'].first == simple_component_model
            end
            mng.specialize 'srv' => simple_component_model
            assert_raises(Syskit::NonSymmetricSpecializationConstraint) { mng.specialize 'srv' => simple_composition_model }
        end

        it "should validate the given specialization block" do
            assert_raises(NameError) do
                mng.specialize 'srv' => simple_composition_model do
                    this_method_does_not_exist
                end
            end
        end

        it "should add the new block to an existing specialization definition if one already exists" do
            spec = mng.specialize 'srv' => simple_component_model
            my_proc = proc { }
            flexmock(spec).should_receive(:add).with(Hash['srv' => [simple_component_model].to_set], my_proc).once
            assert_same spec, mng.specialize('srv' => simple_component_model, &my_proc)
        end

        it "should invalidate the specialized composition models if a block is added to an existing specialization" do
            spec = mng.specialize 'srv' => simple_component_model
            cmp_m = mng.specialized_model(spec)
            assert_same cmp_m, mng.specialized_model(spec)
            mng.specialize('srv' => simple_component_model)
            refute_same cmp_m, mng.specialized_model(spec)
        end
    end

    describe "#specialized_model" do
        # The specialized model that will be given to #specialized_model. We
        # pre-create it so that we can add expectations on it
        #
        # It is already mock'ed
        attr_reader :specialized_model

        before do
            @specialized_model = flexmock(simple_composition_model.new_submodel)
            flexmock(simple_composition_model).should_receive(:new_submodel).and_return(@specialized_model)
        end

        it "should return the base composition model if no specializations are selected" do
            assert_same simple_composition_model,
                mng.specialized_model(Syskit::Models::CompositionSpecialization.new)
        end

        it "should return the same model for the same specializations" do
            srv2 = Syskit::DataService.new_submodel
            spec = Syskit::Models::CompositionSpecialization.new('srv' => [simple_component_model], 'srv2' => [srv2])
            value = mng.specialized_model(spec)
            assert_same value, mng.specialized_model(spec)
        end

        it "should overload the specialized children" do
            srv2 = Syskit::DataService.new_submodel
            specialized_model.should_receive(:overload).with('srv', [simple_component_model]).once
            specialized_model.should_receive(:overload).with('srv2', [srv2]).once
            spec = Syskit::Models::CompositionSpecialization.new('srv' => [simple_component_model], 'srv2' => [srv2])
            mng.specialized_model(spec)
        end

        it "should apply the specialization blocks" do
            srv2 = Syskit::DataService.new_submodel
            spec = Syskit::Models::CompositionSpecialization.new('srv' => [simple_component_model], 'srv2' => [srv2])
            blocks = (1..2).map { Object.new }
            spec.add(Hash.new, blocks)
            specialized_model.should_receive(:apply_specialization_block).with(blocks[0]).once
            specialized_model.should_receive(:apply_specialization_block).with(blocks[1]).once
            mng.specialized_model(spec)
        end

        it "should register the compatible specializations in the new model's specialization manager" do
            srv2 = Syskit::DataService.new_submodel
            spec0 = Syskit::Models::CompositionSpecialization.new('srv2' => [srv2])
            spec1 = Syskit::Models::CompositionSpecialization.new('srv' => [simple_component_model])

            flexmock(Syskit::Models::SpecializationManager).new_instances.should_receive(:register).with(spec1).once
            spec0.compatibilities << spec1
            spec1.compatibilities << spec0
            mng.specialized_model(spec0)
        end

        it "should register the specializations in #applied_specializations" do
            srv2 = Syskit::DataService.new_submodel
            spec0 = Syskit::Models::CompositionSpecialization.new('srv2' => [srv2])
            spec1 = Syskit::Models::CompositionSpecialization.new('srv' => [simple_component_model])
            model = mng.specialized_model(spec0.merge(spec1), [spec0, spec1])
            assert_equal model.applied_specializations, [spec0, spec1]
        end
    end

    describe "#partition_specializations" do
        attr_reader :spec0
        attr_reader :spec1
        attr_reader :spec2

        before do
            @spec0 = Syskit::Models::CompositionSpecialization.new('srv2' => [simple_component_model])
            @spec1 = Syskit::Models::CompositionSpecialization.new('srv' => [simple_component_model])
            @spec2 = Syskit::Models::CompositionSpecialization.new('srv' => [simple_composition_model])
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
            @spec0 = mng.specialize 'srv' => simple_component_model
            @spec1 = mng.specialize 'srv' => simple_composition_model
            @spec2 = mng.specialize 'srv2' => simple_component_model
        end

        it "should return the non-specialized model if it has no specializations" do
            mng.specializations.clear
            assert_equal [[simple_composition_model, []]], mng.find_matching_specializations('srv' => simple_component_model)
        end
        it "should return the non-specialized model if it is given an empty selection" do
            assert_equal [[simple_composition_model, []]], mng.find_matching_specializations(Hash.new)
        end
        it "should return the non-specialized model if it is given a selection that does not match a specialization" do
            assert_equal [[simple_composition_model, []]], mng.find_matching_specializations('srv' => [Syskit::TaskContext.new_submodel])
        end

        it "should return the partitioned specializations that match the selection weakly" do
            selection = {'srv' => simple_component_model}
            flexmock(spec0).should_receive(:weak_match?).with(selection).and_return(true)
            flexmock(spec1).should_receive(:weak_match?).with(selection).and_return(true)
            flexmock(spec2).should_receive(:weak_match?).with(selection).and_return(false)
            flexmock(mng).should_receive(:partition_specializations).with([spec0, spec1]).and_return(obj = Object.new)
            assert_equal obj, mng.find_matching_specializations(selection)
        end
    end

    describe "#matching_specialized_model" do
        it "returns the composition model if no specialization matches" do
            selection = Hash.new
            flexmock(mng).should_receive(:find_matching_specializations).with(selection).and_return([])
            assert_equal simple_composition_model, mng.matching_specialized_model(selection)
        end
        it "returns the composition model for a single match" do
            selection = Hash.new
            match = [flexmock, [flexmock]]
            flexmock(mng).should_receive(:find_matching_specializations).with(selection).and_return([match])
            flexmock(mng).should_receive(:specialized_model).once.
                with(match[0], match[1]).and_return(model = flexmock)
            assert_equal model, mng.matching_specialized_model(selection)
        end
        it "raises if more than one specialization matches and strict is set" do
            selection = Hash.new
            flexmock(mng).should_receive(:find_matching_specializations).with(selection).and_return([1, 2])
            assert_raises(Syskit::AmbiguousSpecialization) do
                mng.matching_specialized_model(selection, :strict => true)
            end
        end
        it "uses the common subset if more than one specialization matches and strict is not set" do
            selection = Hash.new
            matches = [[flexmock, [flexmock]], [flexmock, [flexmock]]]
            flexmock(mng).should_receive(:find_matching_specializations).with(selection).and_return(matches)
            flexmock(mng).should_receive(:find_common_specialization_subset).once.
                with(matches).and_return(matches[0])
            flexmock(mng).should_receive(:specialized_model).once.
                with(matches[0][0], matches[0][1]).and_return(model = flexmock)
            assert_equal model, mng.matching_specialized_model(selection, :strict => false)
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
end

