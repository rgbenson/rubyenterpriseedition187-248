#
# https.rb -- SSL/TLS enhancement for HTTPServer
#
# Author: IPR -- Internet Programming with Ruby -- writers
# Copyright (c) 2001 GOTOU Yuuzou
# Copyright (c) 2002 Internet Programming with Ruby writers. All rights
# reserved.
#
# $IPR: https.rb,v 1.15 2003/07/22 19:20:42 gotoyuzo Exp $

require 'webrick'
require 'openssl'

module WEBrick
  module Config
    HTTP.update(
      :SSLEnable            => true,
      :SSLCertificate       => nil, 
      :SSLPrivateKey        => nil,
      :SSLClientCA          => nil,
      :SSLCACertificateFile => nil,
      :SSLCACertificatePath => nil,
      :SSLCertificateStore  => nil,
      :SSLVerifyClient      => ::OpenSSL::SSL::VERIFY_NONE, 
      :SSLVerifyDepth       => nil,
      :SSLVerifyCallback    => nil,   # custom verification
      :SSLTimeout           => nil,
      :SSLOptions           => nil,
      # Must specify if you use auto generated certificate.
      :SSLCertName          => nil,
      :SSLCertComment       => "Generated by Ruby/OpenSSL"
    )

    osslv = ::OpenSSL::OPENSSL_VERSION.split[1]
    HTTP[:ServerSoftware] << " OpenSSL/#{osslv}"
  end

  class HTTPRequest
    attr_reader :cipher, :server_cert, :client_cert

    alias orig_parse parse

    def parse(socket=nil)
      orig_parse(socket)
      @cipher      = socket.respond_to?(:cipher) ? socket.cipher : nil
      @client_cert = socket.respond_to?(:peer_cert) ? socket.peer_cert : nil
      @server_cert = @config[:SSLCertificate]
    end

    alias orig_parse_uri parse_uri

    def parse_uri(str, scheme="https")
      if @config[:SSLEnable]
        return orig_parse_uri(str, scheme)
      end
      return orig_parse_uri(str)
    end

    alias orig_meta_vars meta_vars

    def meta_vars
      meta = orig_meta_vars
      if @config[:SSLEnable]
        meta["HTTPS"] = "on"
        meta["SSL_CIPHER"] = @cipher ? @cipher[0] : ""
        meta["SSL_CLIENT_CERT"] = @client_cert ? @client_cert.to_pem : ""
        meta["SSL_SERVER_CERT"] = @server_cert ? @server_cert.to_pem : ""
      end
      meta
    end
  end

  class HTTPServer
    alias orig_init initialize

    def initialize(*args)
      orig_init(*args)

      if @config[:SSLEnable] 
        unless @config[:SSLCertificate]
          rsa = OpenSSL::PKey::RSA.new(512){|p, n|
            case p
            when 0; $stderr.putc "."  # BN_generate_prime
            when 1; $stderr.putc "+"  # BN_generate_prime
            when 2; $stderr.putc "*"  # searching good prime,
                                      # n = #of try,
                                      # but also data from BN_generate_prime
            when 3; $stderr.putc "\n" # found good prime, n==0 - p, n==1 - q,
                                      # but also data from BN_generate_prime
            else;   $stderr.putc "*"  # BN_generate_prime
            end
          }
          cert = OpenSSL::X509::Certificate.new
          cert.version = 3
          cert.serial = 0
          name = OpenSSL::X509::Name.new(@config[:SSLCertName])
          cert.subject = name
          cert.issuer = name
          cert.not_before = Time.now
          cert.not_after = Time.now + (365*24*60*60)
          cert.public_key = rsa.public_key

          ef = OpenSSL::X509::ExtensionFactory.new(nil,cert)
          cert.extensions = [
            ef.create_extension("basicConstraints","CA:FALSE"),
            ef.create_extension("subjectKeyIdentifier", "hash"),
            ef.create_extension("extendedKeyUsage", "serverAuth")
          ]
          ef.issuer_certificate = cert
          ext = ef.create_extension("authorityKeyIdentifier",
                                    "keyid:always,issuer:always")
          cert.add_extension(ext)
          if comment = @config[:SSLCertComment]
            cert.add_extension(ef.create_extension("nsComment", comment))
          end
          cert.sign(rsa, OpenSSL::Digest::SHA1.new)

          @config[:SSLPrivateKey] = rsa
          @config[:SSLCertificate] = cert
          @logger.info cert.to_s
        end
        @ctx = OpenSSL::SSL::SSLContext.new
        set_ssl_context(@ctx, @config)
      end
    end

    alias orig_run run

    def run(sock)
      if @config[:SSLEnable] 
        ssl = OpenSSL::SSL::SSLSocket.new(sock, @ctx)
        ssl.accept
        Thread.current[:WEBrickSocket] = ssl
        orig_run(ssl)
        Thread.current[:WEBrickSocket] = sock
        ssl.close
      else
        orig_run(sock)
      end
    end

    private

    def set_ssl_context(ctx, config)
      ctx.key = config[:SSLPrivateKey]
      ctx.cert = config[:SSLCertificate]
      ctx.client_ca = config[:SSLClientCA]
      ctx.ca_file = config[:SSLCACertificateFile]
      ctx.ca_path = config[:SSLCACertificatePath]
      ctx.cert_store = config[:SSLCertificateStore]
      ctx.verify_mode = config[:SSLVerifyClient]
      ctx.verify_depth = config[:SSLVerifyDepth]
      ctx.verify_callback = config[:SSLVerifyCallback]
      ctx.timeout = config[:SSLTimeout]
      ctx.options = config[:SSLOptions]
    end
  end
end
