module Syskit
    module GUI
        class WidgetList < Qt::ScrollArea
            attr_reader :main_layout
            attr_reader :widgets

            def auto_resize?
                @auto_resize
            end

            def initialize(parent = nil, auto_resize: true)
                super(parent)

                self.widget = Qt::Widget.new
                @main_layout = Qt::VBoxLayout.new(widget)
                @widgets = Array.new
                main_layout.size_constraint = Qt::Layout::SetMinAndMaxSize
                @auto_resize = auto_resize
                if auto_resize
                    main_layout.add_stretch(1)
                end
            end

            def add_widget(w)
                widgets << w
                if auto_resize?
                    main_layout.insert_widget(widgets.size - 1, w)
                else
                    main_layout.add_widget(w)
                end
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


