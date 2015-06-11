require 'orocos'
require 'metaruby'
require 'metaruby/dsls/find_through_method_missing'
require 'orocos/remote_processes'
require 'orocos/ruby_tasks/process_manager'
require 'roby'
require 'orogen'

require 'utilrb/hash/map_key'
require 'utilrb/module/include'
require 'utilrb/symbol/to_str'
require 'utilrb/module/define_or_reuse'
require 'utilrb/timepoints'

require 'syskit/base'

require 'syskit/instance_requirements'

require 'syskit/roby_app'
require 'syskit/plan_extension'

# Models
require 'metaruby/dsls'
require 'syskit/custom_require'
require 'syskit/models/base'
require 'syskit/models/orogen_base'
require 'syskit/models/port'
require 'syskit/models/port_access'
require 'syskit/models/data_service'
require 'syskit/data_service'
require 'syskit/models/dynamic_data_service'
require 'syskit/models/component'
require 'syskit/models/bound_data_service'
require 'syskit/models/bound_dynamic_data_service'
require 'syskit/models/composition_specialization'
require 'syskit/models/composition'
require 'syskit/models/task_context'
require 'syskit/models/deployment'
require 'syskit/models/configured_deployment'

# Instances
require 'syskit/port'
require 'syskit/port_access'
require 'syskit/component'
require 'syskit/composition'
require 'syskit/task_context'
require 'syskit/ruby_task_context'
require 'syskit/deployment'
require 'syskit/bound_data_service'

# Dependency injection
require 'syskit/dependency_injection'
require 'syskit/dependency_injection_context'
require 'syskit/instance_selection'
require 'syskit/models/faceted_access'

require 'syskit/models/specialization_manager'

# Actions
require 'syskit/robot'
require 'syskit/actions'

# Coordination models
require 'syskit/coordination'

# The composition child goes there as it is a subclass of InstanceRequirements
require 'syskit/models/composition_child'

# Algorithms
require 'syskit/connection_graphs'
require 'syskit/exceptions'
require 'syskit/network_generation'
require 'syskit/runtime'

require 'syskit/instance_requirements_task'

# App support
require 'syskit/graphviz'
require 'syskit/typelib_marshalling'

# Ros support
require 'syskit/ros'
