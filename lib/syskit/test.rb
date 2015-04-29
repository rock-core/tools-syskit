require 'syskit/test/base'

require 'roby/test/spec'
require 'syskit/test/flexmock_extension'
require 'syskit/test/profile_assertions'
require 'syskit/test/profile_model_assertions'
require 'syskit/test/network_manipulation'

require 'syskit/test/spec'
require 'syskit/test/action_interface_test'
require 'syskit/test/action_test'
require 'syskit/test/profile_test'
require 'syskit/test/component_test'
require 'syskit/test/task_context_test'

class Minitest::Spec
    include FlexMock::ArgumentTypes
    include FlexMock::MockContainer

    def teardown
        super
        flexmock_teardown
    end
end

module Syskit
    Minitest::Spec.register_spec_type Syskit::Test::Spec do |desc|
        desc.class == Module
    end
    Minitest::Spec.register_spec_type Syskit::Test::Spec do |desc|
        desc.kind_of?(Syskit::Models::DataServiceModel)
    end
    Minitest::Spec.register_spec_type Syskit::Test::ActionTest do |desc|
        desc.kind_of?(Roby::Actions::Models::Action) || desc.kind_of?(Roby::Actions::Action)
    end
    Minitest::Spec.register_spec_type Syskit::Test::TaskContextTest do |desc|
        (desc.kind_of?(Class) && desc <= Syskit::TaskContext)
    end
    Minitest::Spec.register_spec_type Syskit::Test::ComponentTest do |desc|
        (desc.kind_of?(Class) && desc <= Syskit::Component && !(desc <= Syskit::TaskContext))
    end
    Minitest::Spec.register_spec_type Syskit::Test::ProfileTest do |desc|
        desc.kind_of?(Syskit::Actions::Profile)
    end
    Minitest::Spec.register_spec_type Syskit::Test::ActionInterfaceTest do |desc|
        (desc.kind_of?(Class) && desc <= Roby::Actions::Interface)
    end
end

