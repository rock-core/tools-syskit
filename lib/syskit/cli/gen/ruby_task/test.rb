require '<%= require_path %>'
<% indent, open, close = ::Roby::CLI::Gen.in_module(*class_name[0..-2]) %>
<%= open %>
<%= indent %>describe <%= class_name.last %> do
<%= indent %>    it "starts" do
<%= indent %>        task = syskit_stub_deploy_configure_and_start(<%= class_name.last %>)
<%= indent %>    end
<%= indent %>end
<%= close %>
