Upgrading from the orocos/roby plugin to syskit
-----------------------------------------------

Two major ideas guided the removal of functionality in syskit:

 * remove implicit disambiguation by name. In quite a few places, names were
   used for disambiguation. It is fine in general, but led to unexpected breakage
   later on in the workflow (i.e. models not being validated anymore because a new port
   got added)
 * use less names, more objects. This is mostly an issue in the internals of
   syskit, but did translate to changed in the user-visible face of it as well.

== Port mappings in provided data services

orocos/roby was using the service name as a way to filter out ambiguities.
This has been removed as being not explicit enough (i.e. "too magic"). One has
now to provide port mappings explicitly as soon as there are more than one
port that matches the data service type. The data service port name is still
used for disambiguation, though.

== Device definition
 * #configure does not exist anymore. Use configuration files or the #configure
   method

== Multirobot configuration in app.yml

  multirobot.use_prefixing => syskit.prefix
  (Note: one can set another prefix that Roby.app.robot_name by setting
  syskit.prefix to a string instead of true)
  multirobot.exclude_from_prefixing => syskit.exclude_from_prefixing
  multirobot.service_discovery.domain => syskit.sd_domain
  multirobot.service_discovery.publish => syskit.publish_on_sd
