= Installation / setup
 * add Roby.app.use "orocos" in config/init.rb and/or config/ROBOT.rb
 * define the component's interfaces in tasks/orocos/interfaces and map them to
   concrete modules in tasks/orocos/project_name.rb (more on that later)

= Models

= Load order
 * first, config/orocos/init.rb is loaded
 * files in tasks/orocos/interfaces/ define the orogen interfaces
 * then files in tasks/orocos/ define the mappings from interfaces to
   components, and are loaded after the interfaces. They are named
   tasks/orocos/<project_name>.rb and are loaded on-demand (i.e. when the orogen
   project <project_name> is required)
