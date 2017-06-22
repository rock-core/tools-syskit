require 'syskit/droby/v5'
Syskit::Models::ComBusModel.include Syskit::DRoby::V5::ComBusDumper
Orocos::RubyTasks::TaskContext.extend Roby::DRoby::V5::DRobyConstant::Dump
Orocos::TaskContext.extend Roby::DRoby::V5::DRobyConstant::Dump

Typelib::Type.include Syskit::DRoby::V5::TypelibTypeDumper
Typelib::Type.extend Syskit::DRoby::V5::TypelibTypeModelDumper
Roby::DRoby::ObjectManager.include Syskit::DRoby::V5::ObjectManagerExtension
Syskit::Actions::Profile.include Syskit::DRoby::V5::ProfileDumper
