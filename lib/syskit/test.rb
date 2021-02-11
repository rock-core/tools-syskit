# frozen_string_literal: true

require "orocos/ruby_tasks/stub_task_context"
require "syskit/test/base"

require "roby/test/spec"
require "syskit/test/flexmock_extension"
require "syskit/test/network_manipulation"
require "syskit/test/profile_assertions"
require "syskit/test/execution_expectations"

require "syskit/test/spec"
require "syskit/test/action_interface_test"
require "syskit/test/action_test"
require "syskit/test/profile_test"
require "syskit/test/component_test"
require "syskit/test/task_context_test"
require "syskit/test/ruby_task_context_test"

Roby::Test::Spec.include Syskit::Test::NetworkManipulation
module Syskit
    Roby::Test.register_spec_type Syskit::Test::Spec do |desc|
        desc.class == Module
    end
    Roby::Test.register_spec_type Syskit::Test::Spec do |desc|
        desc.kind_of?(Syskit::Models::DataServiceModel)
    end
    Roby::Test.register_spec_type Syskit::Test::ActionTest do |desc|
        desc.kind_of?(Roby::Actions::Models::Action) ||
            desc.kind_of?(Roby::Actions::Action)
    end
    Roby::Test.register_spec_type Syskit::Test::TaskContextTest do |desc|
        (desc.kind_of?(Class) && desc <= Syskit::TaskContext)
    end
    Roby::Test.register_spec_type Syskit::Test::RubyTaskContextTest do |desc|
        (desc.kind_of?(Class) && desc <= Syskit::RubyTaskContext)
    end
    Roby::Test.register_spec_type Syskit::Test::ComponentTest do |desc|
        (desc.kind_of?(Class) &&
         desc <= Syskit::Component &&
         !(desc <= Syskit::TaskContext))
    end
    Roby::Test.register_spec_type Syskit::Test::ProfileTest do |desc|
        desc.kind_of?(Syskit::Actions::Profile)
    end
    Roby::Test.register_spec_type Syskit::Test::ComponentTest do |desc|
        (!desc.kind_of?(Class) && desc.kind_of?(Module) && desc <= Syskit::Device)
    end
    Roby::Test.register_spec_type Syskit::Test::ActionInterfaceTest do |desc|
        (desc.kind_of?(Class) && desc <= Roby::Actions::Interface)
    end
end
