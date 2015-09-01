module Syskit
    module GUI
        class WidgetList < Qt::ScrollArea
            attr_reader :main_layout
            def initialize(parent = nil)
                super

                self.widget = Qt::Widget.new
                @main_layout = Qt::VBoxLayout.new(widget)
                main_layout.size_constraint = Qt::Layout::SetMinAndMaxSize
            end

            def add_widget(w)
                main_layout.add_widget(w)
            end

            def add_layout(l)
                main_layout.add_layout(l)
            end

            def resizeEvent(event)
                s = widget.size
                s.width = event.size.width
                widget.size = s
                event.accept
            end
        end
    end
end


