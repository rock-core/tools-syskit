# frozen_string_literal: true

module Syskit
    # Namespace for all the functionality that allows to generate a complete
    # network from a set of requirements
    module NetworkGeneration
        extend Logger::Hierarchy
    end
end

require "syskit/network_generation/dataflow_computation"
require "syskit/network_generation/dataflow_dynamics"
require "syskit/network_generation/merge_solver"
require "syskit/network_generation/system_network_generator"
require "syskit/network_generation/system_network_deployer"
require "syskit/network_generation/engine"
require "syskit/network_generation/async"
require "syskit/network_generation/logger"
