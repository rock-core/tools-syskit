# frozen_string_literal: true

require "syskit/roby_app/log_transfer_server"

require "orocos"
require "orocos/remote_processes"
require "orocos/remote_processes/server"

require "securerandom"

module Syskit
    module RobyApp
        # Service to create a Temporary Root Certificate Authority
        class TmpRootCA
            attr_reader :key, :ca_password, :ca_user

            def initialize(server_ip)
                @key = OpenSSL::PKey::RSA.new 2048 # the CA's public/private key
                @cert = create_self_signed_certificate(server_ip, @key)
                write_private_certificate(@key, @cert)
            end

            def dispose
                @private_certificate_io.close!
            end

            def certificate
                @cert.to_s
            end

            def private_certificate_path
                @private_certificate_io.path
            end

            # Creates a Root Certificate Authority from a root key
            def create_self_signed_certificate(server_ip, key)
                certificate = OpenSSL::X509::Certificate.new
                lifespan = 365 * 24 * 60 * 60
                config_certificate(server_ip, certificate)
                certificate.public_key = key.public_key
                now = Time.now
                certificate.not_before = now
                certificate.not_after = now + lifespan
                add_extensions(server_ip, certificate)
                certificate.sign(key, OpenSSL::Digest::SHA256.new)
                certificate
            end

            def config_certificate(server_ip, certificate)
                certificate.version = 2
                certificate.serial = Time.new.to_i
                subject = OpenSSL::X509::Name.parse("/CN=#{server_ip}")
                certificate.subject = subject
                certificate.issuer = subject
            end

            def add_extensions(server_ip, certificate)
                ef = OpenSSL::X509::ExtensionFactory.new
                ef.subject_certificate = certificate
                ef.issuer_certificate = certificate
                certificate.add_extension(
                    ef.create_extension("subjectAltName", "IP:#{server_ip}", false)
                )
            end

            # Write created Certificate to file signed with a key
            def write_private_certificate(key, cert)
                @private_certificate_io =
                    Tempfile.open("syskit_local_log_transfer", mode: 0o600)
                @private_certificate_io.print key
                @private_certificate_io.print cert
                @private_certificate_io.flush
            end
        end
    end
end
