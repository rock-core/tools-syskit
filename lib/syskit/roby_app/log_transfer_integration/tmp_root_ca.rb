# frozen_string_literal: true

require "orocos"
require "orocos/remote_processes"
require "orocos/remote_processes/server"

require 'securerandom'

class TmpRootCA
    attr_reader :root_key, :root_ca, :cert, :ca_password

    def initialize
        create_root_ca
        create_certificate
        generate_password
    end

    def create_root_ca
        @root_key = OpenSSL::PKey::RSA.new 2048 # the CA's public/private key
        @root_ca = OpenSSL::X509::Certificate.new
        @root_ca.version = 2 # cf. RFC 5280 - to make it a "v3" certificate
        @root_ca.serial = Time.new.to_i # Capture second value number and turns to integer
        @root_ca.subject = OpenSSL::X509::Name.parse "/DC=org/DC=ruby-lang/CN=Ruby CA"
        @root_ca.issuer = @root_ca.subject # root CA's are "self-signed"
        @root_ca.public_key = @root_key.public_key
        @root_ca.not_before = Time.now
        @root_ca.not_after = @root_ca.not_before + 100 * 365 * 24 * 60 * 60 # 100 years validity
        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = @root_ca
        ef.issuer_certificate = @root_ca
        @root_ca.add_extension(ef.create_extension("basicConstraints","CA:TRUE",true))
        @root_ca.add_extension(ef.create_extension("keyUsage","keyCertSign, cRLSign", true))
        @root_ca.add_extension(ef.create_extension("subjectKeyIdentifier","hash",false))
        @root_ca.add_extension(ef.create_extension("authorityKeyIdentifier","keyid:always",false))
        @root_ca.sign(root_key, OpenSSL::Digest::SHA256.new)
    end

    def generate_password
        @ca_password = SecureRandom.base64(15)
    end

    def create_certificate
        key = OpenSSL::PKey::RSA.new 2048
        @cert = OpenSSL::X509::Certificate.new
        @cert.version = 2
        @cert.serial = Time.new.to_i # Capture second value number and turns to integer
        @cert.subject = OpenSSL::X509::Name.parse "/DC=org/DC=ruby-lang/CN=Ruby certificate"
        @cert.issuer = @root_ca.subject # root CA is the issuer
        @cert.public_key = key.public_key
        @cert.not_before = Time.now
        @cert.not_after = @cert.not_before + 1 * 365 * 24 * 60 * 60 # 1 year validity
        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = @cert
        ef.issuer_certificate = root_ca
        @cert.add_extension(ef.create_extension("keyUsage","digitalSignature", true))
        @cert.add_extension(ef.create_extension("subjectKeyIdentifier","hash",false))
        @cert.sign(root_key, OpenSSL::Digest::SHA256.new)
    end

end

tmp_root_ca = TmpRootCA.new
root_ca2 = TmpRootCA.new

# Verification of Certificate and Root CA Public Key
puts tmp_root_ca.cert.verify(root_ca2.root_key)         # False
puts tmp_root_ca.cert.verify(tmp_root_ca.root_key)      # True