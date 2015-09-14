module Syskit
    module GUI
        # Representation of the state of the connected Roby instance
        class GlobalStateLabel < StateLabel
            attr_reader :actions

            # @param [Array<Qt::Action>] the list of actions that can be
            #   performed on the remote Roby instance
            def initialize(actions: Array.new, **options)
                super(extra_style: 'margin-left: 2px; margin-top: 2px; font-size: 10pt;',
                      **options)
                @actions = actions
                declare_state 'CONNECTED', :green
                declare_state 'UNREACHABLE', :red
            end

            def contextMenuEvent(event)
                if !actions.empty?
                    menu = Qt::Menu.new(self)
                    actions.each { |act| menu.add_action(act) }
                    menu.exec(event.global_pos)
                    event.accept
                end
            end

            def mousePressEvent(event)
                event.accept
            end
            def mouseReleaseEvent(event)
                emit clicked
                event.accept
            end
            signals :clicked
        end
    end
end

