require 'syskit/test'

describe Syskit::DependencyInjection do
    include Syskit::SelfTest
    describe "#push" do
        it "applies resolutions recursively layer-by-layer" do
            srv0 = Syskit::DataService.new_submodel
            task0 = Syskit::TaskContext.new_submodel { provides srv0, :as => 'test' }
            di0 = Syskit::DependencyInjection.new
            di0.add(srv0 => task0)
            di1 = Syskit::DependencyInjection.new
            di1.add('name' => srv0)

            context = Syskit::DependencyInjectionContext.new
            context.push di0
            context.push di1
            assert_equal task0.test_srv, context.current_state.explicit['name']
        end
    end
end


