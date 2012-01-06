require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'orocos/roby/app'
require 'orocos/roby'
require 'orocos/roby/test'
require 'orocos/process_server'

module RobyPluginCommonTest
    include Orocos::RobyPlugin::Test
    include Roby::Test
    include Roby::Test::Assertions

    WORK_DIR = File.join(BASE_DIR, 'test', 'working_copy')

    def setup
        ENV['PKG_CONFIG_PATH'] = File.join(WORK_DIR, "prefix", 'lib', 'pkgconfig')
        super
    end
end


