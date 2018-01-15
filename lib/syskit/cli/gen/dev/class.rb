# Load the relevant typekits with import_types_from
# import_types_from 'base'
# You MUST require files that define services that
# you want <%= dev_name.last %> to provide
<% indent, open_code, close_code = ::Roby::CLI::Gen.in_module(*dev_name[0..-2]) %>
<%= open_code %>
<%= indent %>device_type '<%= dev_name.last %>' do
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

<%= indent %>    # # Device models can define configuration extensions, which
<%= indent %>    # # extend the additconfiguration capabilities of the device
<%= indent %>    # # objects, for instance with
<%= indent %>    # extend_device_configuration do
<%= indent %>    #     # Communication baudrate in bit/s
<%= indent %>    #     dsl_attribute :baudrate do |value|
<%= indent %>    #         Float(value)
<%= indent %>    #     end
<%= indent %>    # end
<%= indent %>    # # One can do the following in the robot description:
<%= indent %>    # # robot do
<%= indent %>    # #     device(<%= dev_name.last %>).
<%= indent %>    # #         baudrate(1_000_000) # Use 1Mbit/s
<%= indent %>    # # end
<%= indent %>    # # 
<%= indent %>    # # and then use the information to auto-configure the device
<%= indent %>    # # drivers
<%= indent %>    # # class OroGen::MyDeviceDriver::Task
<%= indent %>    # #     driver_for <%= dev_name.last %>, as: 'driver'
<%= indent %>    # #     def configure
<%= indent %>    # #         super
<%= indent %>    # #         orocos_task.baudrate = robot_device.baudrate
<%= indent %>    # #     end
<%= indent %>    # # end
<%= indent %>    # #
<%= indent %>    # # NOTE: this should be limited to device-specific configurations
<%= indent %>    # # NOTE: driver-specific parameters must be set in the corresponding
<%= indent %>    # # NOTE: oroGen configuration file
<%= indent %>end
<%= close_code %>
