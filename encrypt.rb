#!/usr/bin/env ruby

require "openssl"
require "base64"

def encrypt
	path = "/home/gdanko/.ssh/lms-dev-us-west-1.pem"
	file = File.open(path)
	data = file.read

	cipher = OpenSSL::Cipher::AES.new(256, :CBC)
	cipher.encrypt
	key = cipher.random_key
	#iv = cipher.random_iv

	encoded_key = Base64.encode64(key)
	encoded_text = Base64.encode64(cipher.update(data) + cipher.final)

	puts encoded_key
	puts ""
	puts encoded_text
end

def decrypt
	path = "/tmp/foo"
	file = File.open(path)
	encoded_text = file.read
	
	encoded_key = "0zGEG0kCxZwTQ59yvr/hvkOi4BTVP+EIuN/j2b4MlOs="
	#encoded_text = "Stn4myv1lPPTJOXRdMHVDw=="

	decipher = OpenSSL::Cipher::AES.new(256, :CBC)
	decipher.decrypt
	decipher.key = Base64.decode64(encoded_key)
	plain = decipher.update(Base64.decode64(encoded_text)) + decipher.final
	puts plain
end

#encrypt()
decrypt()
