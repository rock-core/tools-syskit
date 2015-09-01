module Syskit
    module GUI
        class WidgetList < Qt::ScrollArea
            attr_reader :main_layout
            attr_reader :widgets

            def initialize(parent = nil)
                super

                self.widget = Qt::Widget.new
                @main_layout = Qt::VBoxLayout.new(widget)
                @widgets = Array.new
                main_layout.size_constraint = Qt::Layout::SetMinAndMaxSize
            end

            def add_widget(w)
                widgets << w
                main_layout.add_widget(w)
            end

            def children_size_updated
                s = widget.size
                s.height = widgets.inject(0) do |h, w|
                    h + if w.hidden? then 0
                        else w.contents_height
                        end
                end
                widget.size = s
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


