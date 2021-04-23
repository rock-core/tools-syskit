# frozen_string_literal: true

require "orocos"
require "orocos/remote_processes"
require "orocos/remote_processes/server"

require "securerandom"

module Syskit
    module RobyApp
        module LogTransferIntegration
            # Service to create a Temporary Root Certificate Authority
            class TmpRootCA
                attr_reader :root_key, :certificate, :signed_certificate,
                            :ca_password, :ca_user

                def initialize
                    @root_key = OpenSSL::PKey::RSA.new 2048 # the CA's public/private key
                    @root_ca = create_root_ca(@root_key)
                    @cert = create_cert(@root_ca, @root_key)
                    @certificate = write_certificate(@cert)
                    @signed_certificate = write_signed_certificate(@root_key, @cert)
                    generate_password_and_user
                end

                # Establishes initial steps in creating a certificate
                def pre_config(creation_cert:, key:, issuer:, subject:, lifespan:)
                    creation_cert.version = 2
                    creation_cert.serial = Time.new.to_i
                    creation_cert.subject = OpenSSL::X509::Name.parse(subject)
                    creation_cert.issuer = issuer.subject # root CA's are "self-signed"
                    creation_cert.public_key = key.public_key
                    creation_cert.not_before = Time.now
                    creation_cert.not_after = creation_cert.not_before + lifespan
                end

                # Inserts extra properties  to the root CA creation process
                def root_ca_extension_add(ext_fact, root_ca)
                    root_ca.add_extension(
                        ext_fact.create_extension(
                            "basicConstraints", "CA:TRUE", true
                        )
                    )
                    root_ca.add_extension(
                        ext_fact.create_extension(
                            "keyUsage", "keyCertSign, cRLSign", true
                        )
                    )
                    root_ca.add_extension(
                        ext_fact.create_extension(
                            "subjectKeyIdentifier", "hash", false
                        )
                    )
                    root_ca.add_extension(
                        ext_fact.create_extension(
                            "authorityKeyIdentifier", "keyid:always", true
                        )
                    )
                end

                # Inserts extra properties to the certificate creation process
                def certificate_extension_add(ext_fact, cert)
                    cert.add_extension(
                        ext_fact.create_extension(
                            "keyUsage", "digitalSignature", true
                        )
                    )
                    cert.add_extension(
                        ext_fact.create_extension(
                            "subjectKeyIdentifier", "hash", false
                        )
                    )
                end

                # Creates a Root Certificate Authority from a root key
                def create_root_ca(root_key)
                    root_ca = OpenSSL::X509::Certificate.new
                    hundred_years = 100 * 365 * 24 * 60 * 60
                    pre_config(
                        creation_cert: root_ca,
                        key: root_key,
                        subject: "/DC=org/DC=ruby-lang/CN=Ruby CA",
                        issuer: root_ca,
                        lifespan: hundred_years
                    )
                    ef_ca = OpenSSL::X509::ExtensionFactory.new
                    ef_ca.subject_certificate = root_ca
                    ef_ca.issuer_certificate = root_ca
                    root_ca_extension_add(ef_ca, root_ca)
                    root_ca.sign(root_key, OpenSSL::Digest::SHA256.new)
                    root_ca
                end

                # Creates a Certificate authenticated by a Root CA
                def create_cert(root_ca, root_key)
                    key = OpenSSL::PKey::RSA.new 2048
                    cert = OpenSSL::X509::Certificate.new
                    single_year = 1 * 365 * 24 * 60 * 60
                    pre_config(
                        creation_cert: cert,
                        key: key,
                        subject: "/DC=org/DC=ruby-lang/CN=Ruby certificate",
                        issuer: root_ca,
                        lifespan: single_year
                    )
                    ef_cert = OpenSSL::X509::ExtensionFactory.new
                    ef_cert.subject_certificate = cert
                    ef_cert.issuer_certificate = root_ca
                    certificate_extension_add(ef_cert, cert)
                    cert.sign(root_key, OpenSSL::Digest::SHA256.new)
                    cert
                end

                # Write created Certificate to file
                def write_certificate(cert)
                    cert_filepath = File.join(__dir__, "cert.crt")
                    File.open(cert_filepath, "w+") do |f|
                        f.print cert
                    end
                    cert_filepath
                end

                # Write created Certificate to file signed with a key
                def write_signed_certificate(root_key, cert)
                    signed_cert_filepath = File.join(__dir__, "signed_cert.crt")
                    File.open(signed_cert_filepath, "w+") do |f|
                        f.print root_key
                        f.print cert
                    end
                    signed_cert_filepath
                end

                def generate_password_and_user
                    @ca_password = SecureRandom.base64(15)
                    @ca_user = "process server"
                end
            end
        end
    end
end
