# frozen_string_literal: true

require "syskit/droby/v5/droby_dump"

Roby::DRoby::V5::DRobyConstant.map_constant_name(/^::Orocos/, "::Runkit")
