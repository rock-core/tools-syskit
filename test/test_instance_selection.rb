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
end


