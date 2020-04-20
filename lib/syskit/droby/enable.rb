# frozen_string_literal: true

require "syskit/droby/v5"

Orocos::RubyTasks::TaskContext.extend Roby::DRoby::V5::DRobyConstant::Dump
Orocos::TaskContext.extend Roby::DRoby::V5::DRobyConstant::Dump

Typelib::Type.include Syskit::DRoby::V5::TypelibTypeDumper
Typelib::Type.extend Syskit::DRoby::V5::TypelibTypeModelDumper

Roby::DRoby::ObjectManager.include Syskit::DRoby::V5::ObjectManagerExtension
Roby::DRoby::Marshal.include Syskit::DRoby::V5::MarshalExtension

Syskit::InstanceRequirements.include Syskit::DRoby::V5::InstanceRequirementsDumper
Syskit::Models::ComBusModel.include Syskit::DRoby::V5::ComBusDumper
Syskit::Actions::Profile.include Syskit::DRoby::V5::ProfileDumper
Syskit::TaskContext.extend Syskit::DRoby::V5::Models::TaskContextDumper
