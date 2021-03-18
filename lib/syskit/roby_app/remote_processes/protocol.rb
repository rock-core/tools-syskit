# frozen_string_literal: true

module Syskit
    module RobyApp
        module RemoteProcesses
            DEFAULT_PORT = 20_202

            COMMAND_GET_INFO   = "I"
            COMMAND_GET_PID    = "D"
            COMMAND_CREATE_LOG = "C"
            COMMAND_START      = "S"
            COMMAND_END        = "E"
            COMMAND_QUIT       = "Q"
            COMMAND_LOG_UPLOAD_FILE = "U"
            COMMAND_LOG_UPLOAD_STATE = "X"

            EVENT_DEAD_PROCESS = "D"
            RET_STARTED_PROCESS = "P"
            RET_YES = "Y"
            RET_NO  = "N"
        end
    end
end
