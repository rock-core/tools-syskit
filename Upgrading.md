Upgrading from the orocos/roby plugin to syskit
-----------------------------------------------

Two major ideas guided the removal of functionality in syskit:

 * remove implicit disambiguation by name. In quite a few places, names were
   used for disambiguation. It is fine in general, but led to unexpected breakage
   later on in the workflow (i.e. models not being validated anymore because a new port
   got added)
 * remove "too magic" things. Syskit did remove some automatic resolutions that,
   while nice on the surface, made understanding the mechanisms harder by
   introducing "behind the scenes" rules.
 * use less names, more objects. This is mostly an issue in the internals of
   syskit, but did translate to changed in the user-visible face of it as well.

== Loading

Files are now always loaded with the standard Ruby 'require' method. The
required path is relative to the Roby app root (e.g. models/blueprints/pose).
Task libraries and typekits are imported by using using_task_library and
import_types_from at toplevel. For instance:

~~~ ruby
require 'models/blueprints/pose'
import_types_from 'base'
using_task_library 'odometry'
module MyProject
  data_service_type 'SpecializedOrientationSrv' do
    provides Base::OrientationSrv
  end
  class Cmp < Syskit::Composition
    add SpecializedOrientationSrv, :as => 'pose'
    add Odometry::Task, :as => 'odometry'
  end
end
~~~

== Data Services

Data services can now be defined on any module using the #data_service_type
statement. It is customary to suffix the service name with 'Srv'

module MyProject
  data_service_type 'MySrv'
end

The service is then referred to by its constant name (here, MyProject::MySrv)

== Compositions

Compositions are now declared as a subclass of Syskit::Composition with

~~~ ruby
class MyComposition < Syskit::Compositione
end
~~~

They can be placed in any namespace and are referred to by referring to the
class. The Cmp:: prefix does not exist anymore.

In the composition definition, a child is referred to with the _child suffix and
ports with the _port suffix. All children must have an explicit name given with
the :as option. For instance:

~~~ ruby
class Localization < Syskit::Compositione
  add OrientationSrv, :as => 'orientation'
  orientation_child.orientation_samples
end
~~~

Connections are made between children and/or ports using the #connect_to method

~~~ ruby
class Localization < Syskit::Compositione
  add OrientationSrv, :as => 'orientation'
  add Localization::Task, :as => 'task'
  # All four forms are valid, provided that there are no ambiguities
  orientation_child.orientation_samples.connect_to task_child.orientation_samples
  orientation_child.orientation_samples.connect_to task_child
  orientation_child.connect_to task_child.orientation_samples
  orientation_child.connect_to task_child
end
~~~

Exports are still done with #export. What changed is how one refers to the
child's port (see rules above)

== Port mappings in provided data services

orocos/roby was using the service name as a way to filter out ambiguities.
This has been removed as being not explicit enough (i.e. "too magic"). One has
now to provide port mappings explicitly as soon as there are more than one
port that matches the data service type. Explicit mappings are still not needed
if the name of the data service port matches the name on the task.

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
