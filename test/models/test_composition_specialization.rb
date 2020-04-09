# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"
require "minitest/spec"

describe Syskit::Models::CompositionSpecialization do
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :stub_t
    before do
        @stub_t = stub_type "/test_t"
        create_simple_composition_model
    end

    describe "#empty?" do
        it "is true on empty objects" do
            assert Syskit::Models::CompositionSpecialization.new.empty?
        end
        it "is false on objects that do describe some specialization" do
            assert !Syskit::Models::CompositionSpecialization.new("srv" => simple_component_model).empty?
        end
    end

    describe "#merge" do
        it "sets the compatibility list from the argument if empty and adds the argument in the set as well" do
            spec = Syskit::Models::CompositionSpecialization.new "srv" => [simple_component_model], "srv2" => [simple_composition_model]
            test = Syskit::Models::CompositionSpecialization.new
            spec.compatibilities << Object.new
            test.merge(spec)
            assert_equal spec.compatibilities | [spec], test.compatibilities
        end
        it "computes the intersection of compatibility sets" do
            spec = Syskit::Models::CompositionSpecialization.new "srv" => [simple_component_model]
            spec.compatibilities << (spec_compat = Object.new) << Object.new
            test = Syskit::Models::CompositionSpecialization.new "srv2" => [simple_composition_model]
            test.compatibilities << spec_compat << Object.new
            test.merge(spec)
            assert_equal [spec_compat, spec].to_set, test.compatibilities
        end
        it "adds the arguments specialized children and blocks to the receiver" do
            spec = Syskit::Models::CompositionSpecialization.new "srv" => simple_component_model, "srv2" => simple_composition_model
            spec.specialization_blocks << (p0 = proc {}) << (p1 = proc {})

            test = Syskit::Models::CompositionSpecialization.new
            flexmock(test).should_receive(:add).with(spec.specialized_children, spec.specialization_blocks).once
            test.merge(spec)
        end
    end

    describe "#add" do
        it "merges the children specialization mappings with no colliding child names" do
            test = Syskit::Models::CompositionSpecialization.new "srv2" => simple_composition_model
            test.add(Hash["srv" => simple_component_model], [])
            assert_equal Hash["srv" => simple_component_model, "srv2" => simple_composition_model],
                         test.specialized_children
        end
        it "merges the model lists if child names collide" do
            srv2 = Syskit::DataService.new_submodel
            flexmock(Syskit::Models).should_receive(:merge_model_lists).with([srv2], [simple_component_model])
                                    .once.and_return(obj = Object.new)

            test = Syskit::Models::CompositionSpecialization.new "srv" => [srv2]
            test.add(Hash["srv" => [simple_component_model]], [])
            assert_equal Hash["srv" => obj], test.specialized_children
        end
    end

    describe "#compatible_with?" do
        it "returns true if the receiver is empty" do
            test = Syskit::Models::CompositionSpecialization.new
            assert test.compatible_with?(Syskit::Models::CompositionSpecialization.new)
        end
        it "returns true if the argument is empty" do
            spec = Syskit::Models::CompositionSpecialization.new
            test = flexmock(Syskit::Models::CompositionSpecialization.new, :empty? => false)
            assert test.compatible_with?(spec)
        end
        it "returns true if the receiver and the argument are the same" do
            test = flexmock(Syskit::Models::CompositionSpecialization.new, :empty? => false)
            assert test.compatible_with?(test)
        end
        it "returns true if the receiver is in the compatibility list" do
            spec = flexmock(Syskit::Models::CompositionSpecialization.new, :empty? => false)
            test = flexmock(Syskit::Models::CompositionSpecialization.new, :empty? => false)
            flexmock(test.compatibilities).should_receive(:include?).with(spec).and_return(true).once
            assert test.compatible_with?(spec)
        end
        it "returns false if the receiver is not in the compatibility list" do
            spec = flexmock(Syskit::Models::CompositionSpecialization.new, :empty? => false)
            test = flexmock(Syskit::Models::CompositionSpecialization.new, :empty? => false)
            flexmock(test.compatibilities).should_receive(:include?).with(spec).and_return(false).once
            assert !test.compatible_with?(spec)
        end
    end

    describe "#weak_match?" do
        it "should return true if some of the specialized children are not selected and other are with match" do
            spec = Syskit::Models::CompositionSpecialization.new("srv" => [simple_service_model], "other_child" => [simple_component_model])
            assert spec.weak_match?("srv" => simple_component_model)
        end
        it "should return false for over-specialized selections" do
            spec = Syskit::Models::CompositionSpecialization.new("srv" => [simple_component_model.new_submodel], "other_child" => [simple_component_model])
            assert !spec.weak_match?("srv" => simple_component_model)
        end
        it "should return false if some of the specialized children are not selected and other are with no match" do
            spec = Syskit::Models::CompositionSpecialization.new("srv" => [simple_service_model], "other_child" => [simple_component_model])
            assert !spec.weak_match?("srv" => Syskit::TaskContext.new_submodel)
        end
        it "should return true if there is a match and other unrelated entries in the selection" do
            spec = Syskit::Models::CompositionSpecialization.new("srv" => [simple_service_model])
            assert spec.weak_match?("srv" => simple_component_model, "other_child" => [simple_component_model])
        end
        it "should return false if none of the entries in the selection match the specialization" do
            spec = Syskit::Models::CompositionSpecialization.new("other_child" => [simple_service_model])
            assert !spec.weak_match?("srv" => simple_component_model)
        end
        it "should return false if given an unrelated model" do
            spec = Syskit::Models::CompositionSpecialization.new("srv" => [simple_service_model])
            assert !spec.weak_match?("srv" => Syskit::TaskContext.new_submodel)
        end
    end
end
