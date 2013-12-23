require '<%= Roby::App.resolve_robot_in_path("models/#{subdir}/#{basename}") %>'
<% indent, open, close = ::Roby::App::GenBase.in_module(*class_name[0..-2]) %>
<%= open %>
<%= indent %>describe <%= class_name.last %> do
<%= indent %>    # Verifies that the only variation points in the profile are
<%= indent %>    # profile tags. If you want to limit the test to certain definitions,
<%= indent %>    # give them as argument
<%= indent %>    #
<%= indent %>    # You usually want this
<%= indent %>    it_should_be_self_contained
<%= indent %>
<%= indent %>    # Test if all definitions can be instanciated, i.e. are
<%= indent %>    # well-formed networks with no data services
<%= indent %>    #it_can_instanciate_all

<%= indent %>    # Test if specific definitions can be deployed, i.e. are ready to be
<%= indent %>    # started. You want this on the "final" profiles (i.e. the definitions
<%= indent %>    # you will run on the robot)
<%= indent %>    #it_can_deploy_all

<%= indent %>    # If not all definitions can be deployed and/or instanciated, you can
<%= indent %>    # use the forms below, which take a list of definitions to test on
<%= indent %>    #it_can_deploy a_def
<%= indent %>    #it_can_instanciate a_def

<%= indent %>    # See the documentation of Syskit::Test::ProfileAssertions and
<%= indent %>    # Syskit::Test::ProfileModelAssertions for the assertions on resp.
<%= indent %>    # the spec object (to be used in it ... do end blocks) and the spec class
<%= indent %>end
<%= close %>
