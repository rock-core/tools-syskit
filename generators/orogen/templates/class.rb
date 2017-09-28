<% orogen_models.each do |model| %>Syskit.extend_model OroGen.<%= model.name.gsub("::", ".") %> do
    # Customizes the configuration step.
    #
    # The orocos task is available from orocos_task
    #
    # The call to super here applies the configuration on the orocos task. If
    # you need to override properties, do it afterwards
    #
    # def configure
    #     super
    # end
end

<% end %>
