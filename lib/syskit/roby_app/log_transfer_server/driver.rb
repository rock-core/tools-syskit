# frozen_string_literal: true

module Syskit
    module RobyApp
        module LogTransferServer
            # Driver for log transfer FTP server
            class Driver
                def initialize(user, password, data_dir)
                    @user = user
                    @password = password
                    @data_dir = data_dir
                end

                # Return true if the user should be allowed to log in.
                # @param user [String]
                # @param password [String]
                # @return [Boolean]
                #
                # Depending upon the server's auth_level, some of these parameters
                # may be nil.  A parameter with a nil value is not required for
                # authentication.  Here are the parameters that are non-nil for
                # each auth_level:
                # * :user (user)
                # * :password (user, password)

                def authenticate(user, password)
                    user == @user &&
                        (password.nil? || password == @password)
                end

                # Return the file system to use for a user.
                # @param user [String]
                # @return A file system driver

                def file_system(_user)
                    WriteOnlyDiskFileSystem.new(@data_dir)
                end
            end
        end
    end
end
