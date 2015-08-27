module Syskit
    module GUI
        class StateLabel < Qt::Label
            COLORS = Hash[
                blue: "rgb(51, 181, 229)",
                green: "rgb(153, 204, 0)",
                red: "rgb(255, 68, 68)"]

            STYLE = "QLabel { padding: 3; background-color: %s; %s }"
            TEXT_WITH_NAME  = "<b>%s</b>: %s"
            TEXT_WITHOUT_NAME  = "%s"

            # The name that should be displayed in addition to the state
            #
            # If left to nil (the default in {#initialize}), no name will be
            # displayed at all
            #
            # @return [nil,String]
            attr_reader :name

            # Sets or resets the name that should be displayed in addition to
            # the state
            #
            # Set to nil to remove any additional text
            def name=(name)
                @name = name
                update_state(current_state)
            end

            # The current state
            #
            # @return [String]
            attr_reader :state

            # Set of known states
            #
            # StateLabel defines 'INIT' and binds it to the blue color
            attr_reader :states

            # Extra styling elements that should be added to the label
            # stylesheet
            attr_reader :extra_style

            def extra_style=(style)
                @extra_style = style.to_str
                update_state(current_state)
            end

            def initialize(name: nil, extra_style: '', parent: nil)
                super(parent)
                @name = name
                @extra_style = extra_style
                @states = Hash.new

                declare_state :INIT, :blue
                update_state :INIT
            end

            def declare_state(state_name, color)
                if c = COLORS[color]
                    states[state_name.to_s] = COLORS[color]
                else
                    states[state_name.to_s] = color.to_str
                end
            end
            
            # Update to reflect a state change
            def update_state(state)
                state = state.to_s
                if !color = states[state]
                    raise ArgumentError, "unknown state #{state}"
                end

                self.style_sheet = STYLE % [color, extra_style]
                puts STYLE % [color, extra_style]
                self.text =
                    if name then TEXT_WITH_NAME % [name, state]
                    else TEXT_WITHOUT_NAME % [state]
                    end
                @current_state = state
            end

            slots 'update_state(QString)'
        end
    end
end

