require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::InstanceSelection do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    before do
        create_simple_composition_model
    end

    describe "compute_service_selection" do
        it "should map the task to itself if the required model contains a component model" do
            assert_equal Hash[simple_component_model => simple_component_model],
                Syskit::InstanceSelection.compute_service_selection(
                    simple_component_model, [simple_component_model], Hash.new)
        end
    end

    describe "instanciate" do
        it "should return the component if one is selected" do
            sel = Syskit::InstanceSelection.new(c = flexmock)
            assert_same c, sel.instanciate(syskit_engine, nil)
        end
        it "should instanciate the selected requirements if no component is selected" do
            sel = Syskit::InstanceSelection.new(nil, req = Syskit::InstanceRequirements.new)
            flexmock(req).should_receive(:instanciate).and_return(task = Object.new)
            assert_same task, sel.instanciate(syskit_engine, nil)
        end
    end
end


