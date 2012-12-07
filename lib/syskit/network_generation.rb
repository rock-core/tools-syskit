module Syskit
    # Namespace for all the functionality that allows to generate a complete
    # network from a set of requirements
    module NetworkGeneration
    end
end

require 'network_generation/dataflow_computation'
require 'network_generation/dataflow_dynamics'
require 'network_generation/network_merge_solver'
require 'network_generation/engine'
require 'network_generation/logger'
