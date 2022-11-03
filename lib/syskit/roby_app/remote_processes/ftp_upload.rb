# frozen_string_literal: true

module Syskit
    module RobyApp
        module RemoteProcesses
            # Encapsulation of the log file upload process
            class FTPUpload
                def initialize( # rubocop:disable Metrics/ParameterLists
                    host, port, certificate, user, password, file,
                    max_upload_rate: Float::INFINITY
                )

                    @host = host
                    @port = port
                    @certificate = certificate
                    @user = user
                    @password = password
                    @file = file

                    @max_upload_rate = Float(max_upload_rate)
                end

                Result = Struct.new :file, :success, :message do
                    def success?
                        success
                    end
                end

                # Create a temporary file with the FTP server's public key, to pass
                # to FTP.open
                #
                # @yieldparam [String] path the certificate path
                def with_certificate
                    Tempfile.create do |cert_io|
                        cert_io.write @certificate
                        cert_io.flush
                        yield(cert_io.path)
                    end
                end

                # Open the FTP connection
                #
                # @yieldparam [Net::FTP]
                def open
                    with_certificate do |cert_path|
                        Net::FTP.open(
                            @host,
                            private_data_connection: false, port: @port,
                            ssl: { verify_mode: OpenSSL::SSL::VERIFY_PEER,
                                   ca_file: cert_path }
                        ) do |ftp|
                            ftp.login(@user, @password)
                            yield(ftp)
                        end
                    end
                end

                # Open the connection and transfer the file
                #
                # @return [UploadResult]
                def open_and_transfer
                    open { |ftp| transfer(ftp) }
                    Result.new(@file, true, nil)
                rescue StandardError => e
                    Result.new(@file, false, e.message)
                end

                # Do transfer the file through the given connection
                #
                # @param [Net::FTP] ftp
                def transfer(ftp)
                    last = Time.now
                    File.open(@file) do |file_io|
                        ftp.storbinary("STOR #{File.basename(@file)}",
                                       file_io, Net::FTP::DEFAULT_BLOCKSIZE) do |buf|
                            now = Time.now
                            rate_limit(buf.size, now, last)
                            last = Time.now
                        end
                    end
                end

                # @api private
                #
                # Sleep when needed to keep the expected transfer rate
                def rate_limit(chunk_size, now, last)
                    duration = now - last
                    exp_duration = chunk_size / @max_upload_rate
                    # Do not wait, but do not try to "make up" for the bandwidth
                    # we did not use. The goal is to not affect the rest of the
                    # system
                    return if duration > exp_duration

                    sleep(exp_duration - duration)
                end
            end
        end
    end
end
