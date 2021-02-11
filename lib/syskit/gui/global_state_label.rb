# frozen_string_literal: true

module Syskit
    module GUI
        # Representation of the state of the connected Roby instance
        class GlobalStateLabel < StateLabel
            # Actions that are shown when the context menu is activated
            #
            # @return [Array<Qt::Action>] the list of actions that can be
            #   performed on the remote Roby instance (e.g. start/stop ...)
            attr_reader :actions

            # @param [Array<Qt::Action>] the list of actions that can be
            #   performed on the remote Roby instance
            def initialize(actions: [], **options)
                super(extra_style: "margin-left: 2px; margin-top: 2px; font-size: 10pt;",
                      rate_limited: true, **options)
                @actions = actions
                declare_state "STARTING", :blue
                declare_state "RESTARTING", :blue
                declare_state "CONNECTED", :green
                declare_state "UNREACHABLE", :red
            end

            # @api private
            #
            # Qt handler called when the context menu is activated
            def contextMenuEvent(event)
                unless actions.empty?
                    app_state_menu(event.global_pos)
                    event.accept
                end
            end

            # Execute the app state menu
            def app_state_menu(global_pos)
                unless actions.empty?
                    menu = Qt::Menu.new(self)
                    actions.each { |act| menu.add_action(act) }
                    menu.exec(global_pos)
                    true
                end
            end

            # @api private
            #
            # Qt handler called when the mouse is pressed
            def mousePressEvent(event)
                event.accept
            end

            # @api private
            #
            # Qt handler called when the mouse is released
            #
            # It emits the 'clicked' signal
            def mouseReleaseEvent(event)
                emit clicked(event.global_pos)
                event.accept
            end
            signals "clicked(QPoint)"
        end
    end
end
