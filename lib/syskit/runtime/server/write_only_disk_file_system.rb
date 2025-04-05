# frozen_string_literal: true

require "sys/filesystem"

module Syskit
    module Runtime
        module Server
            # Custom write-only file system that detects collision between files
            class WriteOnlyDiskFileSystem
                include Ftpd::DiskFileSystem::Base
                include Ftpd::DiskFileSystem::Mkdir
                include Ftpd::DiskFileSystem::FileWriting
                include Ftpd::DiskFileSystem::Rename
                include Ftpd::Error
                include Ftpd::TranslateExceptions

                def initialize(data_dir, min_free_space: 0)
                    # Ftpd base methods expect data_dir to be a string
                    unless data_dir.respond_to?(:to_s)
                        raise ArgumentError,
                              "data_dir should be convertible into string"
                    end

                    set_data_dir data_dir.to_s
                    @min_free_space = min_free_space
                end

                # Write a file to disk if it does not already exist.
                # @param ftp_path [String] The virtual path
                # @param stream [Ftpd::Stream] Stream that contains the data to write
                #
                # Called for:
                # * STOR
                # * STOU
                #
                # If missing, then these commands are not supported.

                def write(ftp_path, stream)
                    full_path = expand_ftp_path(ftp_path)
                    final_path = File.join(
                        File.dirname(full_path),
                        File.basename(full_path, ".partial")
                    )
                    error "Already exists", 550 if File.exist?(final_path)

                    # Code copied from Ftpd::DiskFileSystem::FileWriting
                    verify_free_space
                    File.open(full_path, "wb") do |file|
                        while (line = stream.read)
                            file.write line
                            verify_free_space
                        end
                    end
                end

                def verify_free_space
                    stat = Sys::Filesystem.stat(@data_dir)
                    available_space = stat.bytes_available

                    return if available_space > @min_free_space

                    raise Ftpd::PermanentFileSystemError,
                          "less than #{@min_free_space} bytes available, log transfer " \
                          "interrupted"
                end

                translate_exceptions :write
            end
        end
    end
end
