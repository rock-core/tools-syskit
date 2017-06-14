require 'roby/app/gen'
class RubyTaskGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = 'compositions'
        super
    end
end

