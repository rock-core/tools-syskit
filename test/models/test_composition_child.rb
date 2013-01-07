require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::Models::CompositionChild do
    describe "#try_resolve" do
        it "returns the composition child if it exists" do
            cmp_m = Syskit::Composition.new_submodel
            cmp = cmp_m.new
            task = Roby::Task.new
            cmp.depends_on task, :role => 'task'
            child = Syskit::Models::CompositionChild.new(cmp_m, 'task')
            assert_equal task, child.try_resolve(cmp)
        end
        it "returns nil if the composition child does not exist" do
            cmp_m = Syskit::Composition.new_submodel
            cmp = cmp_m.new
            child = Syskit::Models::CompositionChild.new(cmp_m, 'task')
            assert_equal nil, child.try_resolve(cmp)
        end
    end
end

