# frozen_string_literal: true

module Syskit
    module GUI
        # Base class for the labels that represent an object and its states
        class StateLabel < Qt::Label
            COLORS = Hash[
                blue: "rgb(51, 181, 229)",
                green: "rgb(153, 204, 0)",
                red: "rgb(255, 68, 68)"]

            STYLE = "QLabel { padding: 3; background-color: %s; %s }"
            TEXT_WITH_NAME = "<b>%s</b>: %s"
            TEXT_WITHOUT_NAME = "%s"

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
                update_text
            end

            # The current state
            #
            # @return [String]
            attr_reader :current_state

            # The current text
            #
            # @return [String]
            attr_reader :current_text

            # The current color
            #
            # @return [String]
            attr_reader :current_color

            # Set of known states
            #
            # StateLabel defines 'INIT' and binds it to the blue color
            attr_reader :states

            # Extra styling elements that should be added to the label
            # stylesheet
            attr_reader :extra_style

            # Sets {#extra_style}
            def extra_style=(style)
                @extra_style = style.to_str
                update_style
            end

            # The default color that will be used for undeclared states
            #
            # If nil, calling {#update_state} with an unknown state will raise
            # an exception
            attr_reader :default_color

            # Sets {#default_color}
            def default_color=(color)
                @default_color = handle_color_argument(color)
            end

            def initialize(name: nil, extra_style: "", parent: nil, rate_limited: false)
                super(parent)
                @rate_limited = rate_limited
                @name = name
                @extra_style = extra_style
                @states = {}

                declare_state :INIT, :blue
                update_state :INIT
            end

            # Declare that the given state should be ignored
            #
            # The display will not be changed when the state changes to an
            # ignored state
            #
            # @param [String] state_name the name of the state that should be
            #   ignored
            def ignore_state(state_name)
                states[state_name.to_s] = nil
            end

            # @api private
            #
            # Helper to handle a color argument
            #
            # @param [String] color the color name (in {COLORS}) or a
            #   stylesheet color (e.g. rgb(20, 30, 50)). Anything that is not a
            #   key in {COLOR} is interpreted as a stylesheet color
            # @return [String] a stylesheet color
            def handle_color_argument(color)
                if c = COLORS[color]
                    COLORS[color]
                else
                    color.to_str
                end
            end

            # Associate a state name and a color
            #
            # @param [String] state_name the state name
            # @param [String] color the color. It can either be a color name in
            #   {COLOR} or a Qt stylesheet color (e.g. 'rgb(20, 30, 50)'). Any
            #   string that is not a color name will be interpreted as a
            #   stylesheet color (i.e. no validation is made)
            def declare_state(state_name, color)
                states[state_name.to_s] = handle_color_argument(color)
                self
            end

            # Declare a color for non-declared states
            #
            # If unset (the default), a non-declared state will be interpreted
            # as an error. Otherwise, this color will be chosen
            def declare_default_color(color)
                self.default_color = handle_color_argument(color)
                self
            end

            # Returns the color that should be used for a given state
            #
            # @param [String] state the state name
            # @return [String] the Qt stylesheet color as defined with
            #   {#declare_state} or, if the state has not been declared, by
            #   {#declare_default_color}
            #
            # @raise [ArgumentError] if the state has not been declared with
            #   {#declare_state} and no defeault color has been set with
            #   {#declare_default_color}
            def color_from_state(state)
                state = state.to_s
                if states.key?(state)
                    states[state]
                elsif color = default_color
                    color
                else
                    raise ArgumentError, "unknown state #{state} and no default color defined"
                end
            end

            # Update to reflect a state change
            #
            # @param [String] state the state name
            # @param [String] text the text to be displayed for this state
            #   change
            # @param [String] color the color to use for this state
            def update_state(state, text: state.to_s, color: color_from_state(state))
                return unless color

                update_style(color)
                update_text(text)
                @current_state = state.to_s
            end

            # Update the label's style to use the given color
            #
            # @param [String] color a Qt stylesheet color (e.g. rgb(20,30,50))
            def update_style(color = current_color)
                @current_color = color
                color = handle_color_argument(color)
                self.style_sheet = format(STYLE, color, extra_style)
            end

            def rate_limited?
                @rate_limited
            end

            # Update the displayed text
            #
            # If {#name} is set, the resulting text is name: text, otherwise
            # just text
            #
            # The text is displayed using the {#current_color} and
            # {#extra_style}
            def update_text(text = current_text)
                return if rate_limited? && @last_update && (Time.now - @last_update) < 1

                @last_update = Time.now

                text = text.to_str
                @current_text = text
                self.text =
                    if name then format(TEXT_WITH_NAME, name, text)
                    else format(TEXT_WITHOUT_NAME, text)
                    end
            end

            slots "update_state(QString)"
        end
    end
end
