# frozen_string_literal: true

module Syskit
    module GUI
        # A dialog that allows to get the parameters to start an app
        class AppStartDialog < Qt::Dialog
            # The combo box to choose the robot name
            #
            # @return [Qt::ComboBox]
            attr_reader :robot_names

            # The checkbox allowing to choose whether the controller blocks
            # should be executed or not
            #
            # @return [Qt::CheckBox]
            attr_reader :start_controller

            # Text used to allow the user to not load any robot configuration
            NO_ROBOT = " -- None -- "

            def initialize(names, parent = nil, default_robot_name: "default")
                super(parent)

                self.window_title = "Start App"

                layout = Qt::VBoxLayout.new(self)
                layout.add_widget(Qt::Label.new("Robot configuration to load:"))
                layout.add_widget(@robot_names = Qt::ComboBox.new)

                robot_names.add_item NO_ROBOT
                names.sort.each_with_index do |n, i|
                    robot_names.add_item(n)
                    if n == default_robot_name
                        robot_names.current_index = i + 1
                    end
                end
                layout.add_widget(@start_controller = Qt::CheckBox.new("Start controller"))
                start_controller.checked = true

                button_box = Qt::DialogButtonBox.new(
                    Qt::DialogButtonBox::Ok | Qt::DialogButtonBox::Cancel
                )
                connect(button_box, SIGNAL("accepted()"), self, SLOT("accept()"))
                connect(button_box, SIGNAL("rejected()"), self, SLOT("reject()"))
                layout.add_widget(button_box)
            end

            # The name of the selected robot
            #
            # @return [String] the robot name, or an empty string if no robot
            #   configuration should be loaded
            def selected_name
                txt = robot_names.current_text
                if txt != NO_ROBOT
                    txt
                else ""
                end
            end

            # Whether the controller should be started
            #
            # @return [Boolean]
            def start_controller?
                start_controller.checked?
            end

            # Executes a {AppStartDialog} in a modal way and returns the result
            #
            # @return [nil,(String,Boolean)] either nil if the dialog was
            #   rejected, or a robot name and a boolean indicating whether the
            #   controller blocks should be executed. The robot name can be
            #   empty to indicate that the dialog was accepted but no robot
            #   configuration should be loaded
            def self.exec(names, parent = nil, default_robot_name: "default")
                dialog = new(names, parent, default_robot_name: default_robot_name)
                if Qt::Dialog::Accepted == dialog.exec
                    [dialog.selected_name, dialog.start_controller?]
                end
            end
        end
    end
end
