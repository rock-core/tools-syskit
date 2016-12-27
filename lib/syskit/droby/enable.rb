require 'syskit/droby/v5'
Syskit::Models::ComBusModel.include Syskit::DRoby::V5::ComBusDumper
Syskit::InstanceRequirements.include Syskit::DRoby::V5::InstanceRequirementsDumper
Typelib::Type.include Syskit::DRoby::V5::TypelibTypeDumper
Typelib::Type.extend Syskit::DRoby::V5::TypelibTypeModelDumper
Roby::DRoby::ObjectManager.include Syskit::DRoby::V5::ObjectManagerExtension
