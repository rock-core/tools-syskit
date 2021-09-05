# frozen_string_literal: true

# This file is called to do application-global configuration. For configuration
# specific to a robot, edit config/NAME.rb, where NAME is the robot name.
#
# Here are some of the most useful configuration options

# Use backward-compatible naming and behaviour, when applicable
#
# For instance, a Syskit app will get the task context models defined at
# toplevel as well as within the OroGen namespace
Roby.app.backward_compatible_naming = false

# Automatically restart deployments that have components either in FATAL_ERROR,
# or that failed to stop
Syskit.conf.auto_restart_deployments_with_quarantines = true

# Set to false to disable old-style type export (using constants)
Syskit.conf.export_types = true

# Set to false to disable old-style task model export (using constants)
OroGen.syskit_model_constant_registration = true

# Set the module's name. It is normally inferred from the app name, and the app
# name is inferred from the base directory name (e.g. an app located in
# bundles/flat_fish would have an app name of flat_fish and a module name of
# FlatFish
#
# Roby.app.module_name = 'Override'

## Enable Syskit

Roby.app.using "syskit"

require "roby/schedulers/temporal"
Roby.scheduler = Roby::Schedulers::Temporal.new
