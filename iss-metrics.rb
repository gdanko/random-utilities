#!/usr/bin/env ruby

require "pp"
require "json"
require "logger"
require "splunk-sdk-ruby"
require "quickbase"
require "optparse"

def get_credentials(logger)
	credentials = Hash.new
	credential_file = sprintf("%s/.splunk", Dir.home)
	unless (File.exists?(credential_file))
		logger.fatal("Cannot open credential file: #{credential_file}.")
		exit 1
	end
	json = File.read(credential_file)
	begin
		credentials = JSON.parse(json)
		return credentials
	rescue JSON::ParserError
		return nil
	end
end

def splunk_search(logger, service, query)
	logger.debug("Executing #{query}")
	stream = service.create_oneshot(
		query,
		:span => "5m",
		:earliest_time => "-2h",
		:latest_time => "now",
		:output_mode => "json"
	)
	data = JSON.parse(stream)
	return data["results"] ? data["results"] : nil
end

logger = Logger.new(STDOUT)
logger.formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

options = Hash.new

optparse = OptionParser.new do |opts|
	opts.separator "Query the war room dashboard and update QuickBase"
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("-d", "--date <date>", "The timestamp for this record in the format: MM-DD-YYYY HH:MM <AM/PM>") do |arg|
		options[:date] = arg
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

# Validate options
if (options[:date])
	unless (options[:date] =~ /^\d\d-\d\d-\d\d\d\d \d\d:\d\d (AM|PM)/i)
		logger.fatal("Timestamp must be in the format MM-DD-YYYY HH:MM <AM|PM>.")
		exit 1
	end
else
	logger.fatal("Missing required date option.")
	exit 1
end

credentials = get_credentials(logger)
db = "bhtwn2734"
token = "dhpxbugc5cs5dsk7tjpzbcc2hi8"

unless (credentials)
	logger.fatal "Failed to parse the credentials file."
	exit 1
end

qb = QuickBase.new({
	"env" => "prod",
	"username" => credentials["quickbase"]["username"],
	"password" => credentials["quickbase"]["password"],
	"token" => token,
	"debug" => "on",
	"db" => db
})

config = {
	:scheme => :https,
	:host => "10.153.210.40",
	:port => 8089,
	:username => credentials["splunk"]["username"],
	:password => credentials["splunk"]["password"]
}

output = Hash.new
block_pct = 0
service = Splunk::connect(config)
puts "Logged in service 0. Token: #{service.token}"
index = "apigateway-pr*"

queries = {
	"RSS /TPS" => {
		"query" => "search index=#{index} api=Intuit.tech.security.rss app=* | eval count=1 | timechart partial=false per_second(count)",
		"key" => "per_second(count)"
	},
	"RSS /Latency" => {
		"query" => "search index=#{index} api=Intuit.tech.security.rss app=* | timechart avg(txTime)",
		"key" => "avg(txTime)"
	},
	"SDT Token /TPS" => {
		"query" => "search index=#{index} xHost=tokenization* | eval count=1 | timechart partial=false per_second(count)",
		"key" => "per_second(count)"
	},
	"SDT Token /Latency" => {
		"query" => "search index=#{index} xHost=tokenization* | timechart avg(txTime)",
		"key" => "avg(txTime)"
	},
	"SDT Detoken /TPS" => {
		"query" => "search index=#{index} xHost=detokenization* | eval count=1 | timechart partial=false per_second(count)",
		"key" => "per_second(count)"
	},
	"SDT Detoken /Latency" => {
		"query" => "search index=#{index} xHost=detokenization* | timechart avg(txTime)",
		"key" => "avg(txTime)"
	},
	"AVS /TPS" => {
		"query" => "search index=#{index} xHost=antivirus.platform.intuit.net | eval count=1 | timechart partial=false per_second(count)",
		"key" => "per_second(count)"
	},
	"AVS /Latency" => {
		"query" => "search index=#{index} xHost=antivirus.platform.intuit.net | timechart avg(txTime)",
		"key" => "avg(txTime)"
	}
}

queries2 ={
	"RSS Block percentage" => "search index=rss-prdidx RiskAssessmentResponse | top recommendation by policy"
}

queries.keys.each do |k|
	query = queries[k]["query"]
	key = queries[k]["key"]
	results = splunk_search(logger, service, query)
	output[k] = sprintf("%.2f",results.last[key])
end

queries2.keys.each do |k|
	results = splunk_search(logger, service, queries2[k])
	results.each do |r|
		if (r["recommendation"] == "block")
			block_pct = block_pct = r["percent"]
		end
	end
end
output["RSS Block percentage"] = sprintf("%.2f", block_pct.to_f)
output["Date"] = options[:date]

qb.AddRecord({
	"fields" => output
})
pp qb.success ? qb.output : qb.errors
