# Load the relevant typekits with import_types_from
# import_types_from 'base'
# You MUST require files that define services that
# you want <%= class_name.last %> to provide
<% indent, open_code, close_code = ::Roby::App::GenBase.in_module(*class_name[0..-2]) %>
<%= open_code %>
<%= indent %>com_bus_type '<%= class_name.last %>', message_type: '/typelib/name/of/the/Type' do
<%= indent %>    # input_port 'in', '/base/Vector3d'
<%= indent %>    # output_port 'out', '/base/Vector3d'
<%= indent %>    #
<%= indent %>    # Tell syskit that this service provides another. It adds the 
<%= indent %>    # ports from the provided service to this service
<%= indent %>    # provides AnotherSrv
<%= indent %>    #
<%= indent %>    # Tell syskit that this service provides another. It maps ports
<%= indent %>    # from the provided service to the one in this service (instead
<%= indent %>    # of adding)
<%= indent %>    # provides AnotherSrv, 'provided_srv_in' => 'in'
<%= indent %>end
<%= close_code %>
