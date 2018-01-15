require '<%= require_path %>'
<% indent, open, close = ::Roby::CLI::Gen.in_module(*dev_name[0..-2]) %>
<%= open %>
<%= indent %>describe <%= dev_name.last %> do
<%= indent %>    # # What one usually wants to test for a Device would be the
<%= indent %>    # # extensions module.
<%= indent %>    # it "allows to specify the baudrate" do
<%= indent %>    #     dev = syskit_stub_device(<%= dev_name.last %>)
<%= indent %>    #     dev.baudrate(1_000_000) # 1Mbit
<%= indent %>    #     assert_equal 1_000_000, dev.baudrate
<%= indent %>    # end
<%= indent %>end
<%= close %>
