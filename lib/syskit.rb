require 'orocos'
require 'roby'
require 'orogen'

require 'utilrb/hash/map_key'
require 'utilrb/module/include'
require 'utilrb/symbol/to_str'
require 'utilrb/module/define_or_reuse'
require 'utilrb/timepoints'

require 'syskit/base'

# Models
require 'syskit/models/base'
require 'syskit/models/port'
require 'syskit/models/port_access'
require 'syskit/models/data_service'
require 'syskit/data_services'
require 'syskit/models/component'
require 'syskit/models/bound_data_service'
require 'syskit/models/specialization_manager'
require 'syskit/models/composition_specialization'
require 'syskit/models/composition'
require 'syskit/models/task_context'
require 'syskit/models/deployment'

# Instances
require 'syskit/port'
require 'syskit/component'
require 'syskit/composition'
require 'syskit/task_context'
require 'syskit/deployment'
require 'syskit/bound_data_service'

# Dependency injection
require 'syskit/dependency_injection'
require 'syskit/dependency_injection_context'
require 'syskit/instance_requirements'
require 'syskit/instance_selection'

# The composition child goes there as it is a subclass of InstanceRequirements
require 'syskit/models/composition_child'

# Algorithms
require 'syskit/connection_graphs'
require 'syskit/exceptions'
require 'syskit/robot'
require 'syskit/network_generation'
require 'syskit/runtime'

require 'syskit/task_scripting'
require 'syskit/selection_tasks'

# App support
require 'syskit/graphviz'
require 'syskit/shell'
require 'syskit/app'
