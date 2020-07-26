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
query = Array.new
creds = Hash.new

optparse = OptionParser.new do |opts|
	opts.separator "Query the Intuit Security Issues QuickBase."
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("-q", "--query <filename>", "Required. Filename with a list of query data.") do |arg|
		options[:query] = arg
	end

	opts.on("-f", "--filename <filename>", "Required. Filename with a list of products to query against. One per line.") do |arg|
		options[:filename] = arg
	end

	opts.on("--first-seen <YYYY-MM-DD>", "Optional. Find items whose FirstSeen field is on or before <YYYY-MM-DD>. (Default: #{options[:first_seen]})") do |arg|
		options[:first_seen] = arg
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

if (options[:query])
	if (File.exists?(options[:query]))
		File.readlines(options[:query]).each {|line|
			query.push(line.chomp.strip)
		}
	else
		logger.error(sprintf("File %s not found.", options[:query]))
	end
else
	logger.fatal(sprintf("You must specify a query file."))
	exit 1
end

if (options[:filename])
	if (File.exists?(options[:filename]))
		File.readlines(options[:filename]).each { |line|
			products.push(line.chomp.strip)
		}
	else
		logger.error(sprintf("File %s not found.", options[:filename]))
	end
else
	logger.fatal(sprintf("You must specify an input file."))
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
	"db" => "bgxr2eqgg"
})

qb.QueryAdd("FirstSeen", "obf", "#{options[:first_seen]}") if options[:first_seen]
qb.QueryAdd("IP - CI Name+ - Product Name+ (System)", "ct", products.join(","))
query.each do |item|
	k,o,v = item.split("|")
	qb.QueryAdd(k, o, v)
end

qb.DoQuery()

if (qb.success)
	puts sprintf("%s records", qb.output.length)
	if (qb.output.length > 0)
		qb.output.each do |r|
			line = sprintf(
				"%s | %s | %s | %s | %s | %s | %s",
				r["@rid"],
				r["ip___ci_name____product_name___system_"],
				r["hostid"],
				r["dns_name"],
				r["issue"],
				r["risk_rating"],
				r["vulnid"]
			)
			if (options[:outfile])
				options[:fh].puts(line)
			else
				puts line
			end
		end
	else
		logger.info("No records found.")
	end
else
	logger.error(qb.errors)
end
