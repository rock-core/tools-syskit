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
<%= indent %>    # Test if specific definitions can either be instanciated, deployed or configured
<%= indent %>    # See the documentation of Syskit::Test::ProfileAssertions and
<%= indent %>    # Syskit::Test::ProfileModelAssertions
<%= indent %>    it_can_instanciate navigation_def
<%= indent %>end
<%= close %>
