#!/usr/bin/env ruby

require "pp"
require "json"
#require "quickbase"
require "/Users/gdanko/git/ruby-quickbase/lib/quickbase/quickbase.rb"
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

logger = Logger.new(STDOUT)
logger.formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

options = {:ticket => nil, :log_type => 1, :days => 7}
creds = Hash.new
products = Array.new

optparse = OptionParser.new do |opts|
	opts.separator "Query the bgxr2eqgg table for items."
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("-f", "--filename <filename>", "Required. Filename with a list of products to query against. One per line.") do |arg|
		options[:filename] = arg
	end

	opts.on("-d", "--days <int>", "Optional. Find items remediated in the past <int> days. (Default: 7)") do |arg|
		options[:days] = arg
	end

	opts.on("--gd", "Not for you.") do |arg|
		options[:gd] = arg
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

if (options[:gd] == true)
	creds["username"] = "gdanko"
	creds["password"] = File.read( sprintf("%s/.gdanko", Dir.home) ).chomp
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

qb.QueryAdd("F+", "xex", "1")
qb.QueryAdd("NEWAssigned Remediation Group", "ct", "Application")
qb.QueryAdd("IP - HostID - CI Name+ - Product Name+ (System) (ref) - BU - Org View (FY14)", "sw", "Tech - CTO")
#qb.QueryAdd("Remediated", "ex", "Remediated")
qb.QueryAdd("Issue Source", "ex", "Qualys")
qb.QueryAdd("LastSeen", "oaf", "-21d")
qb.QueryAdd("Type", "ex", "Prod,Inet")
qb.QueryAdd("CVE", "xct", "CVE-2015-0235")
qb.QueryAdd("Vuln Type", "ex", "Vulnerability,Potential Vulnerability, Vulnerability or Potential Vulnerability")
qb.QueryAdd("IP - CI Name+ - Product Name+ (System)", "ct", products.join(","))
qb.QueryAdd("Risk Rating", "ex", "Medium,High")
qb.DoQuery()

if (qb.success)
pp qb.output;exit
	puts sprintf("%s records", qb.output["record"].length)

	pp qb.output["record"].length
	qb.output["record"].each do |r|
pp r;exit
		puts(sprintf(
			"%s | %s | %s | %s | %s | %s | %s",
			r["rid"],
			r["ip___ci_name____product_name___system_"],
			r["hostid"],
			r["dns_name"],
			r["issue"],
			r["risk_rating"],
			r["vulnid"]
		))
	end
else
	puts qb.errors
end
