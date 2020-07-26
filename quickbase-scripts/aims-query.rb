#!/usr/bin/env ruby

require "pp"
require "json"
require "quickbase"
#require "/Users/gdanko/git/ruby-quickbase/lib/quickbase/quickbase.rb"
require "kconv"
require "etc"
require "optparse"
require "logger"

def auth()
	printf("Quickbase username (#{Etc.getlogin}): ")
	username = STDIN.gets.chomp
	username = username.length > 1 ? username : Etc.getlogin

	printf("Password for #{username}: ")
	system "stty -echo"
	password = STDIN.gets.chomp
	system "stty echo"
	puts ""
	return {"username" => username || nil, "password" => URI.encode(password).gsub(/&/, "%26") || nil}
end

def user_auth()
	output = {"username" => nil, "password" => nil}
	username = Etc.getlogin
	if (username)
		output["username"] = username
		filename = sprintf("%s/.%s", Dir.home, username)
		if (File.exist?(filename))
			output["password"] = URI.encode(File.read(filename).chomp).gsub(/&/, "%26")
		end
	end
	return output
end

logger = Logger.new(STDOUT)
logger.formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

options = {:ticket => nil, :log_type => 1}
products = Array.new
creds = Hash.new

optparse = OptionParser.new do |opts|
	opts.separator "Query the bgxr2eqgg table for items."
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("-o", "--outfile <filename>", "Optional. Send output to <filename>.") do |arg|
		options[:fh] = File.new(arg, "w")
		options[:outfile] = arg
	end

	if (Etc.getlogin == "gdanko")
		opts.on("--gd", "Attempt to login with GD's credentials.") do |arg|
			options[:user_auth] = arg
		end
	end

	if (Etc.getlogin == "jkorn")
		opts.on("--jk", "Attempt to login with JK's credentials.") do |arg|
			options[:user_auth] = arg
		end
	end
end

if (ARGV.length == 0)
	puts optparse
	exit 1
end

begin
	optparse.parse!
rescue OptionParser::ParseError => error
	logger.fatal(error)
	exit 1
end

if (options[:user_auth] == true)
	creds = user_auth()
	unless (creds["username"] && creds["password"])
		creds = auth()
	end
else
	creds = auth()
end

unless (creds["username"] && creds["password"])
	puts "Missing username and/or password."
	exit 1
end

qb = QuickBase.new({
	"env" => "prod",
	"username" => creds["username"],
	"password" => creds["password"],
	"debug" => "on",
	"db" => "54xa5xi4"
})

qb.QueryAdd("Event Date", "oaf", "2015-08-01")
qb.DoQuery()

if (qb.success)
	#puts qb.output.to_json
	qb.output.each do |item|
		pp item
	end
else
	logger.error(qb.errors)
end
