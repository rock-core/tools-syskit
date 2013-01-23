require 'syskit/test'

describe Syskit::Actions::Profile do
    include Syskit::SelfTest

    describe "#use_profile" do
        it "copies the original definitions in the new profile" do
            task_m = Syskit::TaskContext.new_submodel
            src = Syskit::Actions::Profile.new
            src.define 'test', task_m
            flexmock(src.definitions['test']).should_receive(:dup).once.
                and_return(duped = Object.new)
            dst = Syskit::Actions::Profile.new
            dst.use_profile src
            assert_same duped, dst.definitions['test'] 
        end
    end
end

